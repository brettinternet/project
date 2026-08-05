#!/usr/bin/env bash
# CAO flow predicate: dispatch at most six new task attempts per rolling hour.
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/../.." && pwd)
tracker="$repo/cao/scripts/tracker.sh"
budget_file="$repo/.cao/state/budget.json"

skip() { printf '%s\n' '{"execute":false,"output":{}}'; }

[[ $(git -C "$repo" branch --show-current) == main ]] || { skip; exit 0; }
[[ ! -e "$repo/.cao/repository.lock" ]] || {
  # Fail closed: flow execution blocks the CAO event loop, so it cannot safely
  # reconcile the lock through that server's API.
  skip
  exit 0
}

# The CAO flow executor waits synchronously for this script, so a callback to
# its own API cannot be served. The repository lock is acquired before a claim;
# the durable In Progress check covers the period after that claim.
if ! in_progress=$("$tracker" list --status "In Progress" --json | mise exec -- jq -e '.tasks | length'); then
  skip
  exit 0
fi
((in_progress == 0)) || { skip; exit 0; }

now=$(date +%s)
window_start=$now
attempts=0
if [[ -f $budget_file ]]; then
  if ! budget=$(mise exec -- jq -sce 'if length == 1 and (.[0] | type == "object" and (.window_start | type == "number" and floor == .) and (.attempts | type == "number" and floor == . and . >= 0)) then .[0] | {window_start: (.window_start | floor), attempts: (.attempts | floor)} else error("invalid dispatch budget") end' "$budget_file"); then
    skip
    exit 0
  fi
  window_start=$(mise exec -- jq -r '.window_start' <<<"$budget")
  attempts=$(mise exec -- jq -r '.attempts' <<<"$budget")
  if ((now - window_start >= 3600)); then
    window_start=$now
    attempts=0
  fi
fi
((attempts < 6)) || { skip; exit 0; }

if ! task=$($tracker next); then
  skip
  exit 0
fi
id=$(mise exec -- jq -r '.id // empty' <<<"$task")
title=$(mise exec -- jq -r '.title // empty' <<<"$task")
[[ -n $id && -n $title ]] || { skip; exit 0; }
mkdir -p "$(dirname "$budget_file")"
budget_staging=$(mktemp "${budget_file}.XXXXXX")
mise exec -- jq -n --argjson window_start "$window_start" --argjson attempts "$((attempts + 1))" \
  '{window_start:$window_start,attempts:$attempts}' >"$budget_staging"
mv -f "$budget_staging" "$budget_file"
mise exec -- jq -cn --arg id "$id" --arg title "$title" --arg repo "$repo" --arg state_dir "$repo/.cao" \
  '{execute:true,output:{id:$id,title:$title,repo:$repo,state_dir:$state_dir}}'
