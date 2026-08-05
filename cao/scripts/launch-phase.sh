#!/usr/bin/env bash
# Launch and supervise one CAO phase terminal until it reaches a durable outcome.
set -euo pipefail

[[ $# == 4 ]] || { printf 'usage: %s <implement|verify> <task-id> <attempt-root> <worktree>\n' "$0" >&2; exit 2; }
phase=$1
item=$2
root=$3
worktree=$(cd -- "$4" && pwd)
repo=$(cd -- "$(dirname -- "$0")/../.." && pwd)
script_dir="$repo/cao/scripts"
api="${CAO_API_URL:-http://127.0.0.1:${CAO_API_PORT:-9889}}"
interval=${CAO_PHASE_POLL_SECONDS:-10}
timeout=${CAO_PHASE_TIMEOUT_SECONDS:-3600}

case "$phase" in
  implement) profile=project-implementer; provider=codex ;;
  verify) profile=project-verifier; provider=opencode_cli ;;
  *) exit 2 ;;
esac
[[ $interval =~ ^[1-9][0-9]*$ && $timeout =~ ^[1-9][0-9]*$ ]] || exit 2
mkdir -p "$repo/.cao/state" "$repo/.cao/work/$root"

message="Work only Backlog task $item in $worktree. The stable task ID is $item; this attempt is $root. Write the required $phase artifact through $script_dir/repo-state.sh into $repo/.cao/work/$root/."
launch=$(CAO_HOME_DIR="$repo/.cao/home/.aws/cli-agent-orchestrator" cao launch --agents "$profile" --provider "$provider" --headless --async --auto-approve --working-directory "$worktree" "$message")
session=$(mise exec -- jq -r '.session_name // .session // .name // empty' <<<"$launch" 2>/dev/null || true)
[[ -n $session ]] || session=$(sed -n 's/^Session created: //p' <<<"$launch" | tail -1)
[[ -n $session ]] || { printf 'CAO did not return a session name\n' >&2; exit 1; }

terminals=$(curl -fsS --max-time 10 "$api/sessions/$session/terminals") || { printf 'CAO terminal lookup failed\n' >&2; exit 1; }
terminal=$(mise exec -- jq -r 'if type == "array" then .[0].id // .[0].terminal_id else .terminals[0].id // .terminals[0].terminal_id end // empty' <<<"$terminals")
[[ -n $terminal ]] || { printf 'CAO session has no terminal\n' >&2; exit 1; }
CAO_TERMINAL_ID="$terminal" "$script_dir/repo-state.sh" set-terminal "$repo" "$root"
digest=$("$script_dir/repo-state.sh" digest "$worktree")
mise exec -- jq -cn \
  --arg task "$item" --arg attempt "$root" --arg phase "$phase" --arg session "$session" --arg terminal "$terminal" \
  --arg worktree "$worktree" --arg digest "$digest" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{task:$task,attempt:$attempt,phase:$phase,session:$session,terminal:$terminal,worktree:$worktree,digest:$digest,started_at:$started_at}' \
  >>"$repo/.cao/state/events.jsonl"

started=$(date +%s)
while :; do
  now=$(date +%s)
  if ((now - started >= timeout)); then
    "$script_dir/tracker.sh" escalate "$item" --class decision --reason "CAO $phase attempt $root exceeded ${timeout}s without a terminal result" >/dev/null || true
    exit 3
  fi
  if ! terminal_json=$(curl -fsS --max-time 10 "$api/terminals/$terminal"); then
    printf 'CAO terminal became unavailable\n' >&2
    exit 1
  fi
  status=$(mise exec -- jq -r '.status // .terminal.status // empty | ascii_downcase' <<<"$terminal_json")
  case "$status" in
    completed|complete|success|done)
      exit 0
      ;;
    waiting_user_answer)
      "$script_dir/tracker.sh" escalate "$item" --class decision --reason "CAO $phase attempt $root is waiting for user input in terminal $terminal" >/dev/null || true
      exit 3
      ;;
    error|failed|cancelled|canceled)
      printf 'CAO %s terminal %s ended %s\n' "$phase" "$terminal" "$status" >&2
      exit 1
      ;;
    running|working|busy|idle|pending|"")
      sleep "$interval"
      ;;
    *)
      # New provider statuses are not silently treated as success.
      printf 'unknown CAO terminal status: %s\n' "$status" >&2
      exit 1
      ;;
  esac
done
