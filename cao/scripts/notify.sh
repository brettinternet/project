#!/usr/bin/env bash
set -uo pipefail
[ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER_KEY:-}" ] || exit 0
curl -sS --max-time 10 -o /dev/null --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER_KEY" --form-string "title=$1" --form-string "message=$2" --form-string "priority=1" ${3:+--form-string "url=$3"} https://api.pushover.net/1/messages.json || true
