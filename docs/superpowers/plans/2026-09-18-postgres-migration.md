# PostgreSQL Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the SQLite starter with PostgreSQL — row-level locking instead of the single `BEGIN IMMEDIATE` writer transaction — and add `compose.yaml` for local Postgres + app.

**Architecture:** `database.py` keeps engine/model definitions but drops all SQLite branches; `storage.py`'s claim/create/heartbeat/terminal functions each lock only the rows they touch (`SELECT ... FOR UPDATE`, `FOR UPDATE SKIP LOCKED` for claiming) instead of serializing through one writer transaction. Lock order is always Task before Attempt, everywhere, to avoid a deadlock cycle.

**Tech Stack:** SQLAlchemy 2.x ORM, `psycopg[binary]` driver (already a dependency), PostgreSQL 16 via Docker Compose.

**Spec:** `docs/superpowers/specs/2026-09-18-postgres-k8s-ci-design.md` (Phase 1 section)

## Global Constraints

- `RELAY_DATABASE_URL`/`DATABASE_URL` must be a `postgresql+psycopg://` DSN — no `sqlite:///` fallback.
- Every function that locks both a Task and an Attempt row locks the Task first, then the Attempt (prevents deadlock between recovery and heartbeat/terminal paths).
- The `SPEC.md` HTTP protocol, status codes, and lifecycle do not change — only the storage implementation.
- Existing behavior of `storage.py`'s public functions (return values, exceptions raised) must be unchanged; only the transaction/locking mechanism changes.

---

### Task 1: compose.yaml with Postgres + app, two databases

**Files:**
- Create: `compose.yaml`
- Create: `docker/postgres-init.sql`

**Interfaces:**
- Produces: a `postgres` service reachable at `localhost:5432` with user/password `postgres`/`postgres`, database `agent_relay` (app) and `agent_relay_test` (test suite). Later tasks' default `RELAY_DATABASE_URL` values depend on these exact names.

- [ ] **Step 1: Write the Postgres init script**

```sql
-- docker/postgres-init.sql
CREATE DATABASE agent_relay_test;
```

- [ ] **Step 2: Write compose.yaml**

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: agent_relay
    ports:
      - "5432:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./docker/postgres-init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 10

  app:
    build: .
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      RELAY_DATABASE_URL: postgresql+psycopg://postgres:postgres@postgres:5432/agent_relay
    ports:
      - "8000:8000"

volumes:
  postgres-data:
```

- [ ] **Step 3: Bring up Postgres and verify both databases exist**

Run:
```bash
docker compose up -d postgres
docker compose exec postgres pg_isready -U postgres
docker compose exec postgres psql -U postgres -l
```
Expected: `pg_isready` reports `accepting connections`; the `psql -l` listing includes both `agent_relay` and `agent_relay_test`.

- [ ] **Step 4: Commit**

```bash
git add compose.yaml docker/postgres-init.sql
git commit -m "Add compose.yaml with Postgres app and test databases"
```

---

### Task 2: database.py — Postgres-only engine

**Files:**
- Modify: `database.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `DATABASE_URL` (str, Postgres DSN), `engine` (unchanged type: `sqlalchemy.engine.Engine`), `db_session()` (unchanged signature/behavior — plain commit/rollback context manager). `immediate_transaction` is removed; later tasks must not import it.

- [ ] **Step 1: Replace the default URL and drop SQLite branches**

In `database.py`, replace lines 21-23 (`_database_url`):

```python
def _database_url() -> str:
    return (
        os.getenv("RELAY_DATABASE_URL")
        or os.getenv("DATABASE_URL")
        or "postgresql+psycopg://postgres:postgres@localhost:5432/agent_relay"
    )
```

Replace lines 133-156 (`_is_sqlite` through the pragma listener) with:

```python
engine: Engine = create_engine(DATABASE_URL, future=True, pool_pre_ping=True)
```

- [ ] **Step 2: Remove `immediate_transaction`**

Delete the `immediate_transaction` function (lines 178-201 in the original file) entirely. `db_session()` (the plain commit/rollback context manager just above it) is unchanged and becomes the only session helper.

- [ ] **Step 3: Update `recover_expired`'s transaction call**

Change:

```python
def recover_expired() -> int:
    with immediate_transaction() as db:
        return recover_expired_in_session(db, utcnow())
```

to:

```python
def recover_expired() -> int:
    with db_session() as db:
        return recover_expired_in_session(db, utcnow())
```

- [ ] **Step 4: Update `__all__`**

Remove `"immediate_transaction"` from the `__all__` list at the bottom of the file.

- [ ] **Step 5: Verify the module imports cleanly against a running Postgres**

Run (with `docker compose up -d postgres` from Task 1 still running):
```bash
RELAY_DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/agent_relay_test uv run python -c "import database; database.init_db(); print('ok')"
```
Expected: prints `ok` with no errors.

- [ ] **Step 6: Commit**

```bash
git add database.py
git commit -m "database: drop SQLite support, require PostgreSQL"
```

---

### Task 3: storage.authenticate — row lock instead of writer transaction

**Files:**
- Modify: `storage.py`
- Test: `test_agent_relay.py` (existing tests exercise this indirectly; no new test needed — verified in Task 8's full run)

**Interfaces:**
- Consumes: `database.db_session` (from Task 2).
- Produces: `authenticate(token: str) -> Agent` — same signature and exceptions as before.

- [ ] **Step 1: Update the import**

In `storage.py`, remove `immediate_transaction` from the `database` import list (it no longer exists after Task 2).

- [ ] **Step 2: Rewrite `authenticate`**

```python
def authenticate(token: str) -> Agent:
    token_digest = secret_hash(token)
    with db_session() as db:
        agent = db.scalar(select(Agent).where(Agent.token_hash == token_digest).with_for_update())
        if agent is None or not hmac.compare_digest(agent.token_hash, token_digest):
            raise RelayError("invalid_credentials", "The agent token is invalid.", 401)
        agent.last_seen_at = as_db_time(utcnow())
        db.flush()
        db.expunge(agent)
        return agent
```

- [ ] **Step 3: Commit (bundled with Task 4 — see Task 4 Step 4)**

Leave uncommitted; Task 4 finishes the same file and commits both together.

---

### Task 4: storage.create_task — conflict-safe idempotent insert

**Files:**
- Modify: `storage.py`
- Test: `test_agent_relay.py::test_protocol_idempotency_terminal_retry_and_auth_boundary` (existing, must still pass)

**Interfaces:**
- Consumes: `sqlalchemy.exc.IntegrityError`.
- Produces: `create_task(...)` — same signature, same `idempotency_conflict` (409) and success-replay behavior as before, but now correct under concurrent inserts sharing a key (a bare `FOR UPDATE` cannot lock a row that doesn't exist yet).

- [ ] **Step 1: Add the `IntegrityError` import**

```python
from sqlalchemy.exc import IntegrityError
```

- [ ] **Step 2: Rewrite `create_task`**

```python
def create_task(sender_id: str, recipient_id: str, input_text: str, idempotency_key: str | None) -> dict[str, str]:
    with db_session() as db:
        recipient = db.get(Agent, recipient_id)
        if recipient is None:
            raise RelayError("not_found", "Recipient agent not found.", 404)

        task = Task(
            id=new_id("task"),
            sender_id=sender_id,
            recipient_id=recipient_id,
            input=input_text,
            status="queued",
            output=None,
            error=None,
            attempt_count=0,
            idempotency_key=idempotency_key,
            created_at=as_db_time(utcnow()),
            finished_at=None,
        )
        db.add(task)

        if idempotency_key is None:
            db.flush()
            return {"task_id": task.id, "status": task.status}

        try:
            db.flush()
        except IntegrityError:
            db.rollback()
            existing = db.scalar(
                select(Task).where(Task.sender_id == sender_id, Task.idempotency_key == idempotency_key)
            )
            if existing is None:
                raise
            if existing.recipient_id != recipient_id or existing.input != input_text:
                raise RelayError(
                    "idempotency_conflict",
                    "This Idempotency-Key was already used with a different task.",
                    409,
                )
            return {"task_id": existing.id, "status": existing.status}
        return {"task_id": task.id, "status": task.status}
```

Note: the pre-insert idempotency lookup that used to run before the `INSERT` is gone — it can never prevent a race, only the `IntegrityError` fallback does. The unique constraint `uq_task_sender_idempotency` (already defined on `Task`) is the source of truth.

- [ ] **Step 3: Run the idempotency test**

Run: `RELAY_DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/agent_relay_test uv run pytest test_agent_relay.py::test_protocol_idempotency_terminal_retry_and_auth_boundary -v`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add storage.py
git commit -m "storage: row-lock auth, conflict-safe idempotent task creation"
```

---

### Task 5: database.recover_expired_in_session — Task-before-Attempt lock order, recipient scoping

**Files:**
- Modify: `database.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `recover_expired_in_session(db: Session, now: datetime, recipient_id: str | None = None) -> int` — new optional `recipient_id` parameter (default `None` preserves old full-sweep behavior for the background `recover_expired()` loop). Task 6's `claim_one` depends on this exact signature.

- [ ] **Step 1: Rewrite the function**

Replace the existing `recover_expired_in_session`:

```python
def recover_expired_in_session(db: Session, now: datetime, recipient_id: str | None = None) -> int:
    """Expire active leases and requeue/fail their tasks within ``db``.

    Locks the Task row before the Attempt row for each candidate, matching
    the lock order used by heartbeat/commit_terminal, so recovery cannot
    deadlock against them.
    """

    now_db = as_db_time(now)
    query = (
        select(Attempt.task_id)
        .where(Attempt.outcome == "processing", Attempt.lease_expires_at <= now_db)
        .distinct()
    )
    if recipient_id is not None:
        query = query.join(Task, Task.id == Attempt.task_id).where(Task.recipient_id == recipient_id)
    task_ids = list(db.scalars(query))

    count = 0
    for task_id in task_ids:
        task = db.execute(select(Task).where(Task.id == task_id).with_for_update()).scalar_one_or_none()
        if task is None:
            continue
        attempt = db.execute(
            select(Attempt)
            .where(Attempt.task_id == task_id, Attempt.outcome == "processing", Attempt.lease_expires_at <= now_db)
            .with_for_update()
        ).scalar_one_or_none()
        if attempt is None:
            continue
        attempt.outcome = "expired"
        attempt.finished_at = now_db
        if task.status == "processing":
            if task.attempt_count >= MAX_ATTEMPTS:
                task.status = "failed"
                task.error = "attempts_exhausted"
                task.output = None
                task.finished_at = now_db
            else:
                task.status = "queued"
                task.finished_at = None
        count += 1
    return count
```

- [ ] **Step 2: Run the existing expiry test**

Run: `RELAY_DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/agent_relay_test uv run pytest test_agent_relay.py::test_expiry_requeues_and_old_token_is_stale_before_recovery -v`
Expected: PASS (this test calls `main.recover_expired()`, i.e. the `recipient_id=None` full-sweep path).

- [ ] **Step 3: Commit**

```bash
git add database.py
git commit -m "database: lock Task before Attempt in recovery, add recipient scoping"
```

---

### Task 6: storage.claim_one — FOR UPDATE SKIP LOCKED, bounded recovery

**Files:**
- Modify: `storage.py`
- Test: `test_agent_relay.py::test_sqlite_atomic_claims_distribute_without_overlap` (existing, rename per Task 8)

**Interfaces:**
- Consumes: `database.recover_expired_in_session(db, now, recipient_id=...)` (Task 5).
- Produces: `claim_one(agent_id: str, worker_id: str | None) -> dict[str, Any] | None` — same signature and return shape as before.

- [ ] **Step 1: Rewrite `claim_one`**

```python
def claim_one(agent_id: str, worker_id: str | None) -> dict[str, Any] | None:
    with db_session() as db:
        now = utcnow()
        recover_expired_in_session(db, now, recipient_id=agent_id)
        task = db.scalar(
            select(Task)
            .where(Task.recipient_id == agent_id, Task.status == "queued")
            .order_by(Task.created_at, Task.id)
            .limit(1)
            .with_for_update(skip_locked=True)
        )
        if task is None:
            return None
        if task.attempt_count >= MAX_ATTEMPTS:
            task.status = "failed"
            task.error = "attempts_exhausted"
            task.finished_at = as_db_time(now)
            return None

        claim_token = new_secret("clm")
        task.status = "processing"
        task.attempt_count += 1
        lease_expires = as_db_time(now + timedelta(seconds=LEASE_SECONDS))
        db.add(
            Attempt(
                task_id=task.id,
                attempt_number=task.attempt_count,
                worker_id=worker_id,
                claim_token_hash=secret_hash(claim_token),
                claimed_at=as_db_time(now),
                lease_expires_at=lease_expires,
                finished_at=None,
                outcome="processing",
                terminal_action=None,
                terminal_payload_hash=None,
            )
        )
        db.flush()
        return {
            "task_id": task.id,
            "from": task.sender_id,
            "input": task.input,
            "attempt": task.attempt_count,
            "claim_token": claim_token,
            "lease_expires_at": iso_time(lease_expires),
        }
```

`recover_expired_in_session` is now scoped to `agent_id`'s own tasks, so one recipient's expired-lease recovery no longer locks rows belonging to other recipients' claims.

- [ ] **Step 2: Run the concurrent-claims test**

Run: `RELAY_DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/agent_relay_test uv run pytest test_agent_relay.py::test_sqlite_atomic_claims_distribute_without_overlap -v`
Expected: PASS — all 16 concurrent claims succeed with distinct task IDs and no overlap, now via `SKIP LOCKED` instead of a global writer lock.

- [ ] **Step 3: Commit**

```bash
git add storage.py
git commit -m "storage: claim via SELECT FOR UPDATE SKIP LOCKED, bounded recovery"
```

---

### Task 7: storage.heartbeat and commit_terminal — Task-before-Attempt row locks

**Files:**
- Modify: `storage.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `heartbeat(task_id, agent_id, claim_token) -> str` and `commit_terminal(task_id, agent_id, claim_token, *, action, value) -> dict[str, str]` — same signatures, exceptions, and return shapes as before.

- [ ] **Step 1: Rewrite `heartbeat`**

```python
def heartbeat(task_id: str, agent_id: str, claim_token: str) -> str:
    with db_session() as db:
        task = db.execute(select(Task).where(Task.id == task_id).with_for_update()).scalar_one_or_none()
        if task is None or task.recipient_id != agent_id:
            raise RelayError("not_found", "Task not found.", 404)
        attempt = db.execute(
            select(Attempt)
            .where(Attempt.task_id == task_id, Attempt.claim_token_hash == secret_hash(claim_token))
            .with_for_update()
        ).scalar_one_or_none()
        now = utcnow()
        if (
            attempt is None
            or attempt.outcome != "processing"
            or task.status != "processing"
            or db_time(attempt.lease_expires_at) is None
            or db_time(attempt.lease_expires_at) <= now
        ):
            raise RelayError("stale_claim", "This claim is no longer active.", 409)
        attempt.lease_expires_at = as_db_time(now + timedelta(seconds=LEASE_SECONDS))
        db.flush()
        return iso_time(attempt.lease_expires_at) or ""
```

- [ ] **Step 2: Rewrite `commit_terminal`**

```python
def commit_terminal(
    task_id: str,
    agent_id: str,
    claim_token: str,
    *,
    action: Literal["complete", "fail"],
    value: str,
) -> dict[str, str]:
    with db_session() as db:
        task = db.execute(select(Task).where(Task.id == task_id).with_for_update()).scalar_one_or_none()
        if task is None or task.recipient_id != agent_id:
            raise RelayError("not_found", "Task not found.", 404)
        attempt = db.execute(
            select(Attempt)
            .where(Attempt.task_id == task_id, Attempt.claim_token_hash == secret_hash(claim_token))
            .with_for_update()
        ).scalar_one_or_none()
        if attempt is None:
            raise RelayError("stale_claim", "This claim is no longer active.", 409)
        value_digest = payload_hash(value)
        if attempt.outcome in {"completed", "failed"}:
            if attempt.terminal_action == action and attempt.terminal_payload_hash == value_digest:
                return {"task_id": task.id, "status": task.status}
            raise RelayError("conflicting_terminal", "A different terminal result was already accepted.", 409)
        if attempt.outcome != "processing" or task.status != "processing":
            raise RelayError("stale_claim", "This claim is no longer active.", 409)
        now = utcnow()
        if db_time(attempt.lease_expires_at) is None or db_time(attempt.lease_expires_at) <= now:
            raise RelayError("stale_claim", "This claim is no longer active.", 409)
        now_db = as_db_time(now)
        if action == "complete":
            task.output = value
            task.error = None
            task.status = "completed"
            attempt.outcome = "completed"
        else:
            task.output = None
            task.error = value
            task.status = "failed"
            attempt.outcome = "failed"
        task.finished_at = now_db
        attempt.finished_at = now_db
        attempt.terminal_action = action
        attempt.terminal_payload_hash = value_digest
        return {"task_id": task.id, "status": task.status}
```

- [ ] **Step 3: Run the terminal-retry and expiry tests**

Run: `RELAY_DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/agent_relay_test uv run pytest test_agent_relay.py -v`
Expected: all tests in the file PASS.

- [ ] **Step 4: Commit**

```bash
git add storage.py
git commit -m "storage: lock Task before Attempt in heartbeat and commit_terminal"
```

---

### Task 8: Point the test suite at Postgres

**Files:**
- Modify: `test_agent_relay.py`

**Interfaces:**
- Consumes: `agent_relay_test` database from Task 1.
- Produces: nothing new consumed by other tasks; this is the last code task.

- [ ] **Step 1: Change the default test database URL**

Replace:

```python
os.environ.setdefault("RELAY_DATABASE_URL", "sqlite:////tmp/agent-relay-test.db")
```

with:

```python
os.environ.setdefault(
    "RELAY_DATABASE_URL", "postgresql+psycopg://postgres:postgres@localhost:5432/agent_relay_test"
)
```

Keep the surrounding comment; update its wording to say Postgres instead of SQLite scratch file.

- [ ] **Step 2: Rename the SQLite-specific test**

Rename `test_sqlite_atomic_claims_distribute_without_overlap` to `test_atomic_claims_distribute_without_overlap` (the body is unchanged — it already tests outcomes, not the storage engine).

- [ ] **Step 3: Update the module docstring**

Replace the file's top docstring (lines 1-7) — it currently says the "production guarantee comes from SQLite's BEGIN IMMEDIATE boundary" — with:

```python
"""Protocol tests for the PostgreSQL-backed relay.

These tests intentionally exercise storage calls from multiple threads: that
is the closest local equivalent to several worker processes racing to claim
an inbox. The production guarantee comes from PostgreSQL row locks
(``SELECT ... FOR UPDATE [SKIP LOCKED]``), not from a Python lock.
"""
```

- [ ] **Step 4: Run the full suite against Postgres**

Run (with `docker compose up -d postgres` running): `uv run pytest test_agent_relay.py -v`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add test_agent_relay.py
git commit -m "tests: run the protocol suite against PostgreSQL"
```

---

### Task 9: Live integration test checks readiness, not just liveness

**Files:**
- Modify: `test_live_integration.py`

**Interfaces:**
- Produces: no change to the file's public test names; only the reachability check changes.

- [ ] **Step 1: Change the fixture's probe endpoint**

Replace:

```python
        try:
            client.get("/health").raise_for_status()
        except httpx.HTTPError as exc:
            pytest.skip(f"relay not reachable at {BASE_URL}: {exc}")
```

with:

```python
        try:
            client.get("/ready").raise_for_status()
        except httpx.HTTPError as exc:
            pytest.skip(f"relay not ready at {BASE_URL}: {exc}")
```

`/ready` (unchanged in `main.py`) confirms schema/connectivity, not just process liveness — a Postgres-backed relay that's up but can't reach its database should not look reachable to this test.

- [ ] **Step 2: Run it against a live server**

Run:
```bash
docker compose up -d postgres
RELAY_DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/agent_relay uv run uvicorn main:app --port 8000 &
sleep 1
uv run pytest test_live_integration.py -v
kill %1
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test_live_integration.py
git commit -m "test_live_integration: require /ready instead of /health"
```

---

### Task 10: Update SPEC.md and README.md, final full-suite run

**Files:**
- Modify: `SPEC.md`
- Modify: `README.md`

**Interfaces:**
- None — documentation only.

- [ ] **Step 1: Update SPEC.md's storage description**

In the "Components and identity" section, replace the SQLite bullet:

```
- **SQLite (starter):** persists agents, tasks, and delivery attempts. WAL mode and a `BEGIN IMMEDIATE` writer transaction coordinate concurrent claims across API/worker processes. A future student PostgreSQL port can replace this transaction with row locking (for example, `FOR UPDATE SKIP LOCKED`) without changing the protocol.
```

with:

```
- **PostgreSQL:** persists agents, tasks, and delivery attempts. `SELECT ... FOR UPDATE SKIP LOCKED` lets multiple API/worker processes claim different queued tasks concurrently; heartbeat, terminal submission, and lease recovery each lock only the specific Task/Attempt rows they touch, always locking the Task before its Attempt to avoid lock-order deadlocks.
```

Update the "Claim work" section's line about SQLite (`"The SQLite starter uses a BEGIN IMMEDIATE transaction..."`) to describe the `FOR UPDATE SKIP LOCKED` behavior instead.

- [ ] **Step 2: Update README.md**

Replace the title (`# Agent Relay (SQLite starter)`) with `# Agent Relay`. Update the "Run it" section to mention `docker compose up -d postgres` before `uv run uvicorn`, and update the "Storage and delivery behavior" section to describe `database.py`/`storage.py`'s row-locking approach instead of `BEGIN IMMEDIATE`. Remove the closing sentence claiming the starter "does not include ... a PostgreSQL implementation."

- [ ] **Step 3: Run the full test suite one more time**

Run: `uv run pytest -q`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add SPEC.md README.md
git commit -m "docs: describe PostgreSQL storage instead of the SQLite starter"
```

- [ ] **Step 5: Codex review checkpoint**

Per the design spec's sequencing, request a Codex review of the diff introduced by Tasks 1-10 (`git diff main...HEAD` or the equivalent range) before starting Phase 2. Focus areas for the reviewer: lock-order correctness across all four rewritten functions, the `create_task` conflict-handling path, and whether the renamed/updated tests in Tasks 8-9 still exercise the same guarantees as before.

## Spec Coverage Check

- Engine swap, no sqlite fallback → Task 2.
- Lock order Task→Attempt everywhere → Tasks 3, 5, 6, 7 (each rewritten function).
- `claim_one` recipient filter + `SKIP LOCKED` + bounded recovery → Task 6.
- `create_task` conflict-safe insert → Task 4.
- `authenticate` migrated off `immediate_transaction` → Task 3.
- Isolated Postgres test database → Tasks 1, 8.
- `/ready` over `/health` in live integration test → Task 9.
- compose.yaml (postgres + app) → Task 1.
- Documentation → Task 10.
