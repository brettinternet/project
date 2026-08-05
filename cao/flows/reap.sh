#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/../.." && pwd)
python3 "$repo/cao/scripts/reap.py" --repo "$repo"
printf '%s\n' '{"execute":false,"output":{}}'
