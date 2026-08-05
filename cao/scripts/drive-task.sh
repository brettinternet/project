#!/usr/bin/env bash
# Drive one stable Backlog task through an attempt-keyed CAO worktree.
set -euo pipefail

[[ $# == 2 ]] || { printf 'usage: %s <repository> <backlog-task-id>\n' "$0" >&2; exit 2; }
repo=$(cd -- "$1" && pwd)
item=$2
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
state="$script_dir/repo-state.sh"
tracker="$script_dir/tracker.sh"

[[ $item =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { printf 'invalid task ID\n' >&2; exit 2; }
[[ $(git -C "$repo" branch --show-current) == main ]] || { printf 'primary checkout is not main\n' >&2; exit 3; }

# The stable task ID is never reused as a workflow root. Each retry gets an
# independently inspectable branch, worktree, and artifact directory.
attempt="${item,,}.$(date -u +%Y%m%dT%H%M%SZ).$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
CAO_ITEM="$item" "$state" acquire-lock "$repo" "$attempt"
locked=true
release_if_unstarted() {
  [[ ${locked:-false} == true ]] || return 0
  "$tracker" release "$item" >/dev/null 2>&1 || true
  "$state" release-lock "$repo" "$attempt" >/dev/null 2>&1 || true
}
trap release_if_unstarted ERR

"$tracker" claim "$item" >/dev/null
worktree=$("$state" acquire-workspace "$repo" "$attempt")
locked=false

# launch-phase blocks until each terminal reaches a terminal status and writes a
# durable event record. Finalization owns every success or failure cleanup path.
run_phase() {
  set +e
  "$script_dir/launch-phase.sh" "$1" "$item" "$attempt" "$worktree"
  phase_status=$?
  set -e
  if ((phase_status == 3)); then
    "$tracker" release "$item" >/dev/null 2>&1 || true
    "$state" release-lock "$repo" "$attempt" >/dev/null 2>&1 || true
    exit 0
  fi
  return "$phase_status"
}
if ! run_phase implement || ! run_phase verify; then
  "$script_dir/finalize.sh" "$repo" "$attempt" "$item"
  exit 0
fi
"$script_dir/finalize.sh" "$repo" "$attempt" "$item"
