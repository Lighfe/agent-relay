#!/usr/bin/env bash
# Creates the postgres-credentials Secret directly in the cluster with a
# randomly generated password. Never writes the password to disk or git.
# Idempotent: skips if the secret already exists, so redeploys don't
# invalidate the password Postgres already initialized its volume with.
set -euo pipefail

CONTEXT="kind-agent-relay"
KUBECTL="kubectl --context=${CONTEXT}"

if ${KUBECTL} get secret postgres-credentials >/dev/null 2>&1; then
  echo "postgres-credentials secret already exists, leaving it in place"
  exit 0
fi

# The postgres PVC survives a Secret deletion. If it already holds an
# initialized database, generating a fresh password here would not match
# the password baked into that data directory, breaking auth silently
# (postgres accepts connections but every login fails). Refuse instead.
if ${KUBECTL} get pvc postgres-data >/dev/null 2>&1; then
  echo "postgres-data PVC already exists but postgres-credentials Secret is missing." >&2
  echo "Regenerating a new random password would not match the existing database." >&2
  echo "Restore the original Secret, or delete the PVC to reinitialize, before retrying." >&2
  exit 1
fi

PASSWORD=$(openssl rand -hex 16)
DB_URL="postgresql+psycopg://postgres:${PASSWORD}@postgres:5432/agent_relay"

${KUBECTL} create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD="${PASSWORD}" \
  --from-literal=POSTGRES_DB=agent_relay \
  --from-literal=RELAY_DATABASE_URL="${DB_URL}"

echo "postgres-credentials secret created"
