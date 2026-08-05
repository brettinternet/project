#!/usr/bin/env bash
# Finalize one independently verified CAO attempt without touching another checkout.
set -euo pipefail

usage() {
  printf 'usage: %s <repository> <attempt-root> <backlog-task-id>\n' "$0" >&2
  exit 2
}

[[ $# == 3 ]] || usage
repo=$(cd -- "$1" && pwd)
root=$2
item=$3
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state=${CAO_STATE_SCRIPT:-"$script_dir/repo-state.sh"}
tracker=${CAO_TRACKER_SCRIPT:-"$script_dir/tracker.sh"}
checkpoint=${CAO_CHECKPOINT_SCRIPT:-"$script_dir/retry-state.py"}
work_dir="$repo/.cao/work/$root"
implementation="$work_dir/implementation.json"
verification="$work_dir/verify.json"
final="$work_dir/final.json"
worktree="$repo/.worktrees/$root"
retry_identical_limit=3
retry_attempt_limit=6

for tool in git jq task python3 trash; do
  command -v "$tool" >/dev/null || { printf 'finalization requires %s\n' "$tool" >&2; exit 2; }
done
mkdir -p "$work_dir"

failure_fingerprint() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

infrastructure_failure() {
  case $1 in
    implementer_vanished|verifier_vanished|repository_busy|repository_head_changed|ownership_violation|workspace_missing|state_invalid|content_digest_mismatch|tracker_failed|finalization_interrupted)
      return 0 ;;
    *) return 1 ;;
  esac
}

write_result() {
  local outcome=$1 class=${2:-} reason=${3:-} recovery=${4:-}
  mise exec -- jq -n \
    --arg outcome "$outcome" --arg root "$root" --arg item "$item" \
    --arg artifact ".cao/work/$root/final.json" --arg failure_class "$class" \
    --arg failure_reason "$reason" --arg recovery_branch "$recovery" \
    '{phase:"finalize",status:"complete",outcome:$outcome,workflow_root:$root,item:$item,artifact:$artifact}
     + (if $failure_class == "" then {} else {failure_class:$failure_class,failure_reason:$failure_reason} end)
     + (if $recovery_branch == "" then {} else {recovery_branch:$recovery_branch} end)' >"$final"
}

preserve_recovery() {
  local class=$1 recovery="cao/$root"
  if ! git -C "$repo" rev-parse --verify --quiet "refs/heads/$recovery" >/dev/null; then
    printf '\n'
    return
  fi
  if [[ -d $worktree ]] && [[ -n $(git -C "$worktree" status --porcelain --untracked-files=all) ]]; then
    git -C "$worktree" add -A
    git -C "$worktree" -c user.name='CAO' -c user.email='cao@localhost' \
      commit -m "recovery($item): preserve $class from $root" >/dev/null
  fi
  printf '%s\n' "$recovery"
}

# The provider writes the failure note and the released status into the task file
# in the primary checkout. That bookkeeping is what tells the next attempt what
# already went wrong, so it is committed rather than discarded — and committing it
# also leaves the checkout clean, so a later attempt's fast-forward is not refused
# on a path nobody owns. Only this task's file is ever touched; the owner's other
# edits are left alone.
commit_provider_state() {
  local path
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  while IFS= read -r path; do
    git -C "$repo" add -- "$path" || return 0
  done < <(git -C "$repo" diff --name-only -- 'backlog/tasks' 2>/dev/null |
    grep -i -- "/${item}[ .]" || true)
  git -C "$repo" diff --cached --quiet -- 'backlog/tasks' && return 0
  git -C "$repo" -c user.name='CAO' -c user.email='cao@localhost' \
    commit -m "chore($item): record attempt $root outcome" -m "Task: $item" >/dev/null || true
}

release_attempt() {
  "$state" check-lock "$repo" "$root" >/dev/null 2>&1 || return 0
  "$tracker" release "$item" >/dev/null 2>&1 || true
  commit_provider_state
  "$state" release-lock "$repo" "$root" || true
}

fail_attempt() {
  local class=$1 reason=$2 safe=true recovery retry kind attempts identical
  if ! "$state" check-lock "$repo" "$root" >/dev/null 2>&1; then
    class=ownership_violation
    reason="repository lock is missing or owned by another attempt; recovery is preserved"
    safe=false
  fi
  recovery=$(preserve_recovery "$class")
  if [[ $safe == true ]]; then
    kind=task
    infrastructure_failure "$class" && kind=infrastructure
    if ! retry=$(python3 "$checkpoint" "$item" --record-failure "$root" "$kind" "$class" "$(failure_fingerprint "$class")"); then
      write_result fail state_invalid "could not record failure checkpoint" "$recovery"
      release_attempt
      return 0
    fi
    attempts=$(mise exec -- jq -r '.retry.task_attempts' <<<"$retry")
    identical=$(mise exec -- jq -r '.retry.identical_failures' <<<"$retry")
    if [[ $kind == task ]] && { (( identical >= retry_identical_limit )) || (( attempts >= retry_attempt_limit )); }; then
      "$tracker" escalate "$item" --class decision --reason "CAO stopped retrying after $attempts task failures ($identical identical $class): $reason. Recovery branch: $recovery" >/dev/null || true
    else
      "$tracker" note "$item" "CAO attempt $root failed ($class): $reason${recovery:+. Recovery branch: $recovery}" >/dev/null || true
    fi
  fi
  write_result fail "$class" "$reason" "$recovery"
  release_attempt
}

valid_artifact() {
  local artifact=$1 phase=$2
  mise exec -- jq -e --arg item "$item" --arg root "$root" --arg phase "$phase" '
    type == "object"
    and .phase == $phase
    and .item == $item
    and .workflow_root == $root
    and (.outcome == "pass" or .outcome == "fail")
    and (.baseline_sha | type == "string" and test("^[0-9a-f]{40}$"))
    and (.digest | type == "string" and test("^[0-9a-f]{64}$"))
    and (.changed_files | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
    and (.changed_files == (.changed_files | sort | unique))
    and (.summary | type == "string" and length > 0)
    and (.commit_subject | type == "string" and length > 0)
    and (.commit_body | type == "string" and length > 0)
    and (if .outcome == "fail" then (.failure_class | type == "string" and length > 0) and (.failure_reason | type == "string" and length > 0) else true end)
  ' "$artifact" >/dev/null
}
unexpected_finalization_error() {
  local status=$?
  trap - ERR
  fail_attempt finalization_interrupted "unexpected finalization command failure (exit $status)"
  exit 0
}
trap unexpected_finalization_error ERR

if [[ ! -f $implementation ]] || ! valid_artifact "$implementation" implement; then
  fail_attempt implementer_vanished "implementation artifact is missing or invalid"
  exit 0
fi
if [[ ! -f $verification ]] || ! valid_artifact "$verification" verify; then
  fail_attempt verifier_vanished "verification artifact is missing or invalid"
  exit 0
fi
if [[ $(mise exec -- jq -r '.outcome' "$implementation") != pass ]]; then
  fail_attempt "$(mise exec -- jq -r '.failure_class // "implementation_failed"' "$implementation")" "$(mise exec -- jq -r '.failure_reason // "implementation failed"' "$implementation")"
  exit 0
fi
if [[ $(mise exec -- jq -r '.outcome' "$verification") != pass ]]; then
  fail_attempt "$(mise exec -- jq -r '.failure_class // "verification_failed"' "$verification")" "$(mise exec -- jq -r '.failure_reason // "independent verification failed"' "$verification")"
  exit 0
fi
if ! mise exec -- jq -en --slurpfile implementation "$implementation" --slurpfile verification "$verification" '
  $implementation[0] as $implementation | $verification[0] as $verification |
  $implementation.baseline_sha == $verification.baseline_sha and
  $implementation.digest == $verification.digest and
  $implementation.changed_files == $verification.changed_files
' >/dev/null; then
  fail_attempt artifact_contract_mismatch "implementation and verification observed different repository states"
  exit 0
fi
if ! "$state" check-lock "$repo" "$root" >/dev/null 2>&1; then
  fail_attempt ownership_violation "repository lock is missing or owned by another attempt"
  exit 0
fi
[[ -d $worktree ]] || { fail_attempt workspace_missing "attempt worktree does not exist"; exit 0; }
[[ $(git -C "$repo" branch --show-current) == main ]] || {
  fail_attempt repository_head_changed "primary checkout is not on main"
  exit 0
}
task_path=$("$tracker" --worktree "$worktree" show "$item" | mise exec -- jq -r '.task.path') || {
  fail_attempt tracker_failed "could not read task state before finalization"
  exit 0
}

baseline=$(mise exec -- jq -r '.baseline_sha' "$verification")
digest=$(mise exec -- jq -r '.digest' "$verification")
[[ $(git -C "$repo" rev-parse refs/heads/main) == "$baseline" ]] || { fail_attempt repository_head_changed "main moved from reviewed baseline $baseline"; exit 0; }
[[ $("$state" digest "$worktree") == "$digest" ]] || { fail_attempt content_digest_mismatch "worktree no longer matches verification digest"; exit 0; }

python3 "$checkpoint" "$item" --begin --attempt "$root" --baseline "$baseline" --digest "$digest" --task-path "$task_path" >/dev/null || {
  fail_attempt state_invalid "finalization checkpoint rejected reviewed attempt"
  exit 0
}

summary=$(mise exec -- jq -r '.summary' "$verification")
"$tracker" --worktree "$worktree" prepare-complete "$item" --summary "$summary" >/dev/null || {
  fail_attempt tracker_failed "could not prepare the completed task state"
  exit 0
}
expected=$(mise exec -- jq -c --arg path "$task_path" '.changed_files + [$path] | sort | unique' "$verification")
actual=$("$state" changed-files "$worktree" | mise exec -- jq -R 'select(length > 0)' | mise exec -- jq -sc 'sort | unique')
[[ $actual == "$expected" ]] || { fail_attempt scope_drift "worktree changes differ from reviewed files plus the Backlog task"; exit 0; }
task_blob=$(git -C "$worktree" hash-object "$task_path")
python3 "$checkpoint" "$item" --advance --attempt "$root" --stage prepared --task-blob "$task_blob" >/dev/null || {
  fail_attempt state_invalid "could not checkpoint prepared task state"
  exit 0
}

subject=$(mise exec -- jq -r '.commit_subject' "$verification")
body=$(mise exec -- jq -r '.commit_body' "$verification")
grep -Fqx "Task: $item" <<<"$body" || body+=$'\n\nTask: '"$item"
while IFS= read -r path; do git -C "$worktree" add -- "$path"; done < <(mise exec -- jq -r '.changed_files[]' "$verification")
git -C "$worktree" add -- "$task_path"
git -C "$worktree" commit -m "$subject" -m "$body"
commit_sha=$(git -C "$worktree" rev-parse HEAD)
python3 "$checkpoint" "$item" --advance --attempt "$root" --stage committed --commit "$commit_sha" >/dev/null

# The provider claim lives in the primary checkout. Release it, then restore the
# task file to its reviewed baseline bytes: the provider also rewrites
# `updated_date`, so a semantic release alone leaves the primary checkout dirty
# on the exact path the fast-forward is about to change, and Git refuses it.
if ! "$tracker" release "$item" >/dev/null; then
  fail_attempt tracker_failed "could not release the primary task claim before integration"
  exit 0
fi
if git -C "$repo" cat-file -e "$baseline:$task_path" 2>/dev/null; then
  git -C "$repo" checkout -- "$task_path"
else
  trash "$repo/$task_path" 2>/dev/null || true
fi
if ! (cd "$worktree" && task ci >"$work_dir/task-ci.log" 2>&1); then
  fail_attempt post_commit_ci_failed "task ci failed before integration; see .cao/work/$root/task-ci.log"
  exit 0
fi
python3 "$checkpoint" "$item" --advance --attempt "$root" --stage ci_passed --commit "$commit_sha" >/dev/null
[[ $(git -C "$repo" rev-parse refs/heads/main) == "$baseline" ]] || { fail_attempt repository_head_changed "main moved before integration"; exit 0; }
if ! git -C "$repo" merge --ff-only "$commit_sha" >/dev/null; then
  fail_attempt repository_head_changed "fast-forward of main to reviewed commit was refused"
  exit 0
fi
python3 "$checkpoint" "$item" --advance --attempt "$root" --stage integrated --commit "$commit_sha" >/dev/null
python3 "$checkpoint" "$item" --record-delivery --attempt "$root" --commit "$commit_sha" --delivered-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
write_result pass
"$state" release-workspace "$repo" "$root"
"$state" release-lock "$repo" "$root"
