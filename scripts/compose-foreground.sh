#!/usr/bin/env bash
set -euo pipefail

# Hum must own this shell directly, not a Task/Varlock wrapper that could exit
# before cleanup finishes. Each command still gets the scoped Varlock environment.
trap 'mise exec -- task server:compose:services:down' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mise exec -- task server:compose:wait
mise exec -- task server:compose:logs
