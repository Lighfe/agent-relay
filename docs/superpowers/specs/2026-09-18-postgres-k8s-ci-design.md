# Postgres + Kubernetes + CI/CD migration

Status: design, not implemented. Reviewed once by Codex (findings folded in below).

## Goal

Port Agent Relay from the SQLite starter to PostgreSQL, deploy it to a local
`kind` cluster, and automate build/test/deploy in CI. Protocol and lifecycle
in `SPEC.md` do not change — only storage and deployment.

## Phase 1 — PostgreSQL

**Engine swap.** `database.py` drops the SQLite branch and pragma listener.
`DATABASE_URL` must be a Postgres DSN (`postgresql+psycopg://...`); no
`sqlite:///` fallback. `as_db_time`/`db_time` (naive-UTC storage) stay as-is.

**Locking, replacing the single `immediate_transaction()` seam:**

- **Lock order is always Task → Attempt.** Every function that touches both
  locks the Task row first, then any Attempt rows, to prevent the deadlock
  Codex flagged between `recover_expired_in_session` (was Attempt→Task) and
  `heartbeat`/`commit_terminal` (Task→Attempt).
- **`claim_one`**: `SELECT ... FROM tasks WHERE recipient_id = :agent_id AND
  status = 'queued' ORDER BY created_at, id LIMIT 1 FOR UPDATE SKIP LOCKED`
  (recipient filter preserved — dropping it was Codex's first finding).
  Bound recovery to the claimed task's own expired attempts, not a full-table
  sweep, so recovery no longer serializes every claim.
- **`create_task`**: `FOR UPDATE` cannot protect an insert. Attempt the
  insert directly; on `IntegrityError` against
  `uq_task_sender_idempotency`, re-select the existing row and apply the
  same conflict/return logic as today. Keep the unique constraint as the
  source of truth.
- **`heartbeat` / `commit_terminal`**: lock the Task row, then its Attempt
  row, re-check status/expiry after acquiring locks (values may have changed
  under `autoflush=True`), then proceed exactly as today.
- **`authenticate`**: also migrate off `immediate_transaction()` — lock only
  the Agent row being updated (`last_seen_at`).
- A plain `recover_expired()` background pass still exists for the lease
  sweep, using the same Task→Attempt lock order per row it processes.

**Testing.** Point `RELAY_DATABASE_URL` at an isolated Postgres instance for
`test_agent_relay.py` (not SQLite) so the locking behavior is actually
exercised. `test_live_integration.py`'s client fixture should require
`/ready` (schema + connectivity), not just `/health`, so an unreachable
server fails the run instead of silently skipping.

**compose.yaml**: `postgres` (postgres:16, named volume, `pg_isready`
healthcheck) + `app` (built from the existing `Dockerfile`, `depends_on:
postgres: condition: service_healthy`, `RELAY_DATABASE_URL` pointing at the
`postgres` service).

## Phase 2 — kind + kubectl

Install `kind` and `kubectl` (standard binary releases, one-time local
setup). `kind create cluster --name agent-relay`.

## Phase 3 — Kubernetes manifests

Plain YAML in `k8s/` (no Kustomize): a Secret for Postgres credentials
(generated locally, not committed), a PVC with no `storageClassName` (binds
to kind's default local-path provisioner), Postgres Deployment + ClusterIP
Service (readiness via `pg_isready`), app Deployment (readiness `/ready`,
liveness `/health`, `imagePullPolicy: Never` so it can't silently fall back
to an older tag from a registry) + ClusterIP Service.

Flow: build image with a git-SHA tag → `kind load docker-image
agent-relay:<sha> --name agent-relay` → `kubectl apply -f k8s/` with that
same tag in the app Deployment → `kubectl rollout status` on both
Deployments (Postgres first, app depends on it being ready via its own
readiness probe rather than an init container) → `kubectl port-forward
svc/agent-relay 8000:8000` → run `test_live_integration.py` against the
forwarded port.

## Phase 4 — CI (`.github/workflows/ci.yml`)

**`test` job** (any Linux runner): Postgres as a GitHub Actions service
container, `uv sync`, `pytest -q`, then start `uvicorn` against that
Postgres and run `test_live_integration.py`.

**`build-and-deploy` job** (`needs: test`): build the image tagged with the
short git SHA. Deploy steps gated on `if: ${{ env.ACT == 'true' }}` (act sets
this; false on GitHub-hosted runners, so the job no-ops there rather than
failing against an unreachable cluster). Gated steps: verify the mounted
Docker socket and kubeconfig actually reach the existing local `kind`
cluster (fail fast if not, rather than hanging on an unreachable API
server), `kind load docker-image` the new tag, apply the same tag to the
app Deployment, `kubectl rollout status --timeout=...`.

This is designed for local runs via `act` (or a self-hosted runner with the
socket/kubeconfig mounted) — not GitHub-hosted infrastructure.

## Sequencing

Implement and review each phase in order, with a Codex review checkpoint
after each phase (including this design). Phase 2 has no code to review;
its checkpoint is confirming the cluster comes up.

## Out of scope

Migrating existing SQLite data, Ingress/NodePort exposure, Kustomize/Helm,
ephemeral CI-only kind clusters.
