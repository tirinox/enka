#!/bin/sh
# Wait for Postgres, apply migrations, then hand off to the real command.
# Doing it here (rather than in a separate one-shot service) means `make up`
# always lands on a schema-current, working system.
set -e

python -m app.db.wait
echo "[entrypoint] running migrations"
alembic upgrade head
echo "[entrypoint] starting: $*"
exec "$@"
