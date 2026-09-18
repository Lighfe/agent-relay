#!/usr/bin/env bash
# Creates the postgres-credentials Secret directly in the cluster with a
# randomly generated password. Never writes the password to disk or git.
# Idempotent: skips if the secret already exists, so redeploys don't
# invalidate the password Postgres already initialized its volume with.
set -euo pipefail

if kubectl get secret postgres-credentials >/dev/null 2>&1; then
  echo "postgres-credentials secret already exists, leaving it in place"
  exit 0
fi

PASSWORD=$(openssl rand -hex 16)
DB_URL="postgresql+psycopg://postgres:${PASSWORD}@postgres:5432/agent_relay"

kubectl create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD="${PASSWORD}" \
  --from-literal=POSTGRES_DB=agent_relay \
  --from-literal=RELAY_DATABASE_URL="${DB_URL}"

echo "postgres-credentials secret created"
