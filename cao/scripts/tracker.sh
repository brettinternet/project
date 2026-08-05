#!/usr/bin/env bash
# The only production entry point for Backlog.md CLI access.
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/../.." && pwd)
state="$repo/.cao/state"
mkdir -p "$state/escalations"
# Notification titles name the project instead of hard-coding a product name, so
# this pattern drops into any repository unchanged.
project=${CAO_PROJECT_NAME:-$(basename "$repo")}

usage() {
  printf 'usage: %s [--worktree PATH] {list|show|next|claim|release|note|prepare-complete|escalate|block} ...\n' "$0" >&2
  exit 2
}

worktree=$repo
if [[ ${1:-} == --worktree ]]; then
  [[ $# -ge 3 ]] || usage
  worktree=$(cd -- "$2" && pwd)
  shift 2
fi

backlog() {
  (cd "$worktree" && mise exec -- backlog "$@")
}

notify() {
  "$repo/cao/scripts/notify.sh" "$@" || true
}

require_id() {
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'invalid task ID\n' >&2
    exit 2
  }
}

priority_rank() {
  case ${1,,} in high) printf 0;; medium) printf 1;; low) printf 2;; *) printf 3;; esac
}

next_task() {
  local listing statuses candidate_ids id task
  listing=$(backlog task list --json)
  statuses=$(mise exec -- jq -c '.tasks | map({key:.id, value:.status}) | from_entries' <<<"$listing")
  candidate_ids=$(mise exec -- jq -r '
    [.tasks[]
     | select(.status == "To Do")
     | select((.labels // []) as $labels
       | (["container", "human", "deferred", "blocked", "escalated"]
          | any(. as $label | $labels | index($label))) | not)]
    | sort_by(
        (if ((.priority // "") | ascii_downcase) == "high" then 0
         elif ((.priority // "") | ascii_downcase) == "medium" then 1
         elif ((.priority // "") | ascii_downcase) == "low" then 2 else 3 end),
        (.ordinal // 2147483647), .id
      )
    | .[].id
  ' <<<"$listing")
  [[ -n $candidate_ids ]] || return 1

  # The list response is the status snapshot, but only task views include
  # dependencies. Inspect candidates in selection order and stop at the first
  # dependency-ready task; this preserves scheduling order without loading
  # every eligible task.
  while IFS= read -r id; do
    task=$(backlog task "$id" --json)
    if mise exec -- jq -e --argjson statuses "$statuses" '
      [.task.dependencies[]? | $statuses[.] == "Done"] | all
    ' <<<"$task" >/dev/null; then
      mise exec -- jq '.task' <<<"$task"
      return 0
    fi
  done <<<"$candidate_ids"
  return 1
}

subcommand=${1:-}
case "$subcommand" in
  list)
    shift
    backlog task list "$@"
    ;;
  show)
    require_id "${2:-}"
    backlog task "$2" --json
    ;;
  next)
    next_task
    ;;
  claim)
    require_id "${2:-}"
    backlog task edit "$2" --status "In Progress"
    ;;
  release)
    require_id "${2:-}"
    backlog task edit "$2" --status "To Do"
    ;;
  note)
    require_id "${2:-}"
    [[ -n ${3:-} ]] || usage
    backlog task edit "$2" --append-notes "$3"
    ;;
  prepare-complete)
    require_id "${2:-}"
    id=$2
    shift 2
    summary=''
    while [[ $# -gt 0 ]]; do
      case $1 in
        --summary) summary=${2:?}; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ -n $summary ]] || usage
    task=$(backlog task "$id" --json)
    args=(task edit "$id" --status Done --append-final-summary "$summary")
    while IFS= read -r index; do args+=(--check-ac "$index"); done < <(
      mise exec -- jq -r '.task.acceptanceCriteria | to_entries[] | select(.value.checked | not) | .key + 1' <<<"$task"
    )
    while IFS= read -r index; do args+=(--check-dod "$index"); done < <(
      mise exec -- jq -r '.task.definitionOfDone | to_entries[] | select(.value.checked | not) | .key + 1' <<<"$task"
    )
    backlog "${args[@]}"
    ;;
  escalate|block)
    action=$subcommand
    require_id "${2:-}"
    id=$2
    shift 2
    reason=''
    class=''
    while [[ $# -gt 0 ]]; do
      case $1 in
        --reason) reason=${2:?}; shift 2 ;;
        --class) class=${2:?}; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ -n $reason && -n $class ]] || usage
    case $class in credentials|account|payment|decision|upstream|gate) ;; *) printf 'invalid blocker class\n' >&2; exit 2;; esac
    if [[ $action == escalate ]]; then
      backlog task edit "$id" --add-label escalated --status "To Do" --append-notes "ESCALATED($class): $reason"
      mise exec -- jq -n --arg task "$id" --arg reason "$reason" --arg class "$class" --argjson timestamp "$(date +%s)" \
        '{task:$task,reason:$reason,class:$class,escalated_at:$timestamp}' >"$state/escalations/$id.json"
      notify "$project: $id needs you" "$class: $reason"
    else
      backlog task edit "$id" --add-label blocked --append-notes "BLOCKED($class): $reason. ORACLE: confirmed external prerequisite — $reason"
      notify "$project: $id blocked" "$class: $reason"
    fi
    ;;
  *) usage ;;
esac
