#!/usr/bin/env bash
set -euo pipefail
: "${COMPOSE_PROJECT_NAME:?Run through the project Varlock environment}"
export COMPOSE_DISABLE_ENV_FILE=1

# Stop only this environment's containers. Preserve data for the next hum up.
trap 'docker compose --profile services stop --timeout 10' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker compose --profile services up -d --wait --wait-timeout 120
docker compose --profile services logs --follow --no-color
