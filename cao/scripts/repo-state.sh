#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s {changed-files|untracked-files|digest|acquire-lock|set-terminal|check-lock|release-lock|reconcile-lock|acquire-workspace|release-workspace|workspace-path} [repository] [root]\n' "$0" >&2
  printf '       %s write-artifact <repository> <phase> <root> <item> [options]\n' "$0" >&2
  exit 2
}

command_name=${1:-}
# write-artifact takes named options, so it is parsed separately rather than being
# squeezed into the positional commands' argument limit.
if [[ $command_name != write-artifact ]]; then
  [[ $# -ge 1 && $# -le 3 ]] || usage
fi
repo=${2:-$PWD}
repo=$(cd -- "$repo" && pwd)

case "$command_name" in
  changed-files|untracked-files|digest|acquire-lock|set-terminal|check-lock|release-lock|reconcile-lock| \
    write-artifact|acquire-workspace|release-workspace|workspace-path) ;;
  *) usage ;;
esac

git_cmd=(git -C "$repo" -c core.excludesFile=/dev/null)
lock_dir="$repo/.cao/repository.lock"
lock_owner=${3:-}

# Gitignored build caches shared into each worktree by symlink, so `task ci` in
# an attempt worktree stays warm. Declared once because two places must agree:
# acquire/release-workspace create and remove them, and is_runtime_path must
# exclude them from repository state. A trailing slash pattern like
# `node_modules/` in .gitignore does not match a symlink, so without that
# exclusion the link itself is reported as untracked project content and the
# digest tries to `cat` a directory. Add each area's cache directory here.
linked_caches=(client/node_modules)

# Repository state is normally read from the primary checkout and can be
# redirected to an attempt worktree by write-artifact --worktree. Runtime state
# and artifacts stay in the primary checkout; all task mutations are committed
# from the attempt worktree during finalization.
state_root=$repo
state_cmd=("${git_cmd[@]}")

lock_usage() {
  printf '%s requires a workflow root ID\n' "$command_name" >&2
  exit 2
}

if [[ $command_name == acquire-lock ]]; then
  [[ -n $lock_owner ]] || lock_usage
  [[ -n ${CAO_ITEM:-} ]] || {
    printf 'acquire-lock requires CAO_ITEM\n' >&2
    exit 2
  }
  mkdir -p "$repo/.cao"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    printf 'repository_busy\n' >&2
    exit 3
  fi
  baseline_sha=$("${git_cmd[@]}" rev-parse --verify HEAD) || {
    rmdir "$lock_dir"
    exit 4
  }
  # Provenance is written before `root`, and `root` is what every other command
  # treats as proof of ownership. A crash between the two therefore leaves a
  # lock that reconcile-lock reports as `lock_unowned` rather than one that
  # silently claims a workflow that never started mutating anything.
  printf '%s\n' "$baseline_sha" >"$lock_dir/base"
  printf '{"root":"%s","item":"%s","baseline_sha":"%s","acquired_at":"%s","pid":%s,"host":"%s","terminal_id":"%s"}\n' \
    "$lock_owner" "${CAO_ITEM:?CAO_ITEM is required for a CAO repository lock}" "$baseline_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" \
    "$(uname -n)" "${CAO_TERMINAL_ID:-}" >"$lock_dir/owner.json"
  printf '%s\n' "$lock_owner" >"$lock_dir/root"
  exit 0
fi
if [[ $command_name == set-terminal ]]; then
  [[ -n $lock_owner ]] || lock_usage
  [[ -n ${CAO_TERMINAL_ID:-} ]] || {
    printf 'set-terminal requires CAO_TERMINAL_ID\n' >&2
    exit 2
  }
  [[ -f "$lock_dir/root" && $(<"$lock_dir/root") == "$lock_owner" ]] || {
    printf 'repository_busy\n' >&2
    exit 3
  }
  # Same-directory staging plus `mv -f` so a crash never leaves a partially
  # rewritten owner record.
  owner_staging=$(mktemp "$lock_dir/.owner.XXXXXX")
  jq --arg terminal "$CAO_TERMINAL_ID" '.terminal_id = $terminal' "$lock_dir/owner.json" >"$owner_staging"
  mv -f "$owner_staging" "$lock_dir/owner.json"
  exit 0
fi

# reconcile-lock answers one question for an unattended restart: may dispatch
# start a workflow? It compares the durable lock owner against the live workflow
# list, and never mutates or destroys anything.
#
# A dirty primary checkout is deliberately no longer a halt condition. Workflows
# work in their own worktrees, so uncommitted changes here belong to the owner and
# are none of dispatch's business. Requiring a clean tree meant the owner could not
# touch the repository without stopping delivery, and it is what made an unowned
# dirty tree look like a fault rather than someone working.
if [[ $command_name == reconcile-lock ]]; then
  if [[ ! -d $lock_dir ]]; then
    printf 'clear\n'
    exit 0
  fi
  recorded_owner=''
  if [[ -f "$lock_dir/root" ]]; then
    recorded_owner=$(cat -- "$lock_dir/root" 2>/dev/null || true)
    recorded_owner=${recorded_owner//[$'\r\n']/}
  fi
  if [[ -z $recorded_owner ]]; then
    printf 'lock_unowned repository lock has no durable workflow owner\n'
    exit 1
  fi
  terminal_id=$(jq -r '.terminal_id // empty' "$lock_dir/owner.json" 2>/dev/null || true)
  if [[ -z $terminal_id ]]; then
    printf 'owner_unprovable lock owner has no CAO terminal ID\n'
    exit 1
  fi
  if ! terminal=$(curl -fsS --max-time 5 "http://127.0.0.1:${CAO_API_PORT:-9889}/terminals/$terminal_id" 2>/dev/null); then
    printf 'owner_unprovable CAO API unavailable\n'
    exit 1
  fi
  status=$(jq -r '.status // empty' <<<"$terminal")
  case "$status" in
    completed|error|unknown|'') printf 'owned_dead %s\n' "$recorded_owner" ;;
    *) printf 'owned_live %s\n' "$recorded_owner" ;;
  esac
  exit 1
fi

# A workflow works in its own worktree so it never mutates the owner's checkout.
# That checkout is shared: a workflow holding the lock cannot tell its own dirty
# paths from the owner's in-progress edits, and recovery stashing the difference
# destroyed the owner's work twice. A worktree removes the ambiguity by
# construction — everything in it belongs to the workflow.
# Runtime artifacts stay in the primary checkout. Build caches are gitignored,
# so they are linked rather than rebuilt, which keeps `task ci` warm.
worktree_path() {
  printf '%s/.worktrees/%s' "$repo" "$1"
}
worktree_branch() {
  printf 'cao/%s' "$1"
}

if [[ $command_name == workspace-path ]]; then
  [[ -n $lock_owner ]] || lock_usage
  worktree_path "$lock_owner"
  exit 0
fi

if [[ $command_name == acquire-workspace ]]; then
  [[ -n $lock_owner ]] || lock_usage
  [[ -f "$lock_dir/root" && $(<"$lock_dir/root") == "$lock_owner" ]] || {
    printf 'acquire-workspace requires the repository lock\n' >&2
    exit 3
  }
  tree=$(worktree_path "$lock_owner")
  branch=$(worktree_branch "$lock_owner")
  if [[ -d $tree ]]; then
    printf '%s\n' "$tree"
    exit 0
  fi
  baseline_sha=$(<"$lock_dir/base")
  baseline_sha=${baseline_sha//[$'\r\n']/}
  mkdir -p "$repo/.worktrees"
  # Branched from the recorded baseline, not from whatever main happens to be, so
  # the reviewed state matches the provenance written before any mutation.
  "${git_cmd[@]}" worktree add --quiet -b "$branch" "$tree" "$baseline_sha" || {
    printf 'worktree_create_failed\n' >&2
    exit 4
  }
  for cache in "${linked_caches[@]}"; do
    [[ -d "$repo/$cache" ]] || continue
    mkdir -p "$(dirname "$tree/$cache")"
    ln -s "$repo/$cache" "$tree/$cache" 2>/dev/null || true
  done
  printf '%s\n' "$tree"
  exit 0
fi

if [[ $command_name == release-workspace ]]; then
  [[ -n $lock_owner ]] || lock_usage
  tree=$(worktree_path "$lock_owner")
  branch=$(worktree_branch "$lock_owner")
  # Linked caches are removed before the worktree so `git worktree remove` can
  # never follow a symlink into the primary checkout's build output.
  for cache in "${linked_caches[@]}"; do
    [[ -L "$tree/$cache" ]] && trash "$tree/$cache" 2>/dev/null
  done
  if [[ -d $tree ]]; then
    "${git_cmd[@]}" worktree remove --force "$tree" 2>/dev/null ||
      trash "$tree" 2>/dev/null || true
  fi
  "${git_cmd[@]}" worktree prune 2>/dev/null || true
  "${git_cmd[@]}" branch -D "$branch" 2>/dev/null || true
  exit 0
fi

if [[ $command_name == check-lock || $command_name == release-lock ]]; then
  [[ -n $lock_owner ]] || lock_usage
  [[ -f "$lock_dir/root" ]] || {
    printf 'repository_busy\n' >&2
    exit 3
  }
  [[ $(<"$lock_dir/root") == "$lock_owner" ]] || {
    printf 'repository_busy\n' >&2
    exit 3
  }
  if [[ $command_name == check-lock ]]; then
    exit 0
  fi
  for lock_file in "$lock_dir/root" "$lock_dir/base" "$lock_dir/owner.json"; do
    [[ ! -e $lock_file ]] || trash "$lock_file" 2>/dev/null || {
      printf 'repository_lock_release_failed\n' >&2
      exit 4
    }
  done
  rmdir "$lock_dir"
  exit 0
fi

is_runtime_path() {
  case "$1" in
    .cao|.cao/*)
      return 0
      ;;
    # Per-workflow worktrees live inside the repository. The tree is read with
    # core.excludesFile=/dev/null, so without this a workflow's own worktree
    # would be counted as untracked project content it had just created.
    .worktrees | .worktrees/*)
      return 0
      ;;
    *)
      local cache
      for cache in "${linked_caches[@]}"; do
        [[ $1 == "$cache" || $1 == "$cache"/* ]] && return 0
      done
      return 1
      ;;
  esac
}

untracked_files_nul() {
  local path
  while IFS= read -r -d '' path; do
    is_runtime_path "$path" && continue
    # shellcheck disable=SC2153
    # Only regular files carry content the digest can read. A symlink or an
    # untracked directory would make `cat` fail mid-pipeline and silently change
    # the hash.
    [[ -f "$state_root/$path" && ! -L "$state_root/$path" ]] || continue
    printf '%s\0' "$path"
  done < <("${state_cmd[@]}" ls-files --others --exclude-standard -z)
}

untracked_files() {
  untracked_files_nul | tr '\0' '\n' | LC_ALL=C sort -u
}

changed_files() {
  {
    "${state_cmd[@]}" diff --name-only HEAD -- . \
      ':(exclude).cao'
    untracked_files
  } | LC_ALL=C sort -u
}

if [[ $command_name == untracked-files ]]; then
  untracked_files
  exit 0
fi

if [[ $command_name == changed-files ]]; then
  changed_files
  exit 0
fi

content_digest() {
  {
    printf 'tracked-patch\0'
    "${state_cmd[@]}" diff --no-ext-diff --binary HEAD -- . \
      ':(exclude).cao'
    printf '\0untracked-content\0'
    while IFS= read -r path; do
      printf 'path\0%s\0' "$path"
      cat "$state_root/$path"
      printf '\0'
    done < <(untracked_files)
  } | shasum -a 256 | awk '{print $1}'
}

if [[ $command_name == digest ]]; then
  content_digest
  exit 0
fi

# write-artifact exists because the mechanical half of the phase contract was the
# single largest source of workflow failure: nine of roughly twenty-seven
# recoveries were implementation_artifact_invalid, verification_artifact_invalid,
# or artifact_contract_mismatch — the work was correct and the paperwork was not.
# A model was being asked to hand-transcribe a 40-character SHA, a 64-character
# digest, and a sorted unique file list into JSON, then reproduce all three
# byte-identically in a second file one phase later. Those fields are observations
# of the repository, so they are computed here instead, which also makes
# cross-phase agreement structural rather than a coincidence. Prose stays with the
# agent, and the result is validated at the point of creation so a contract error
# fails inside the phase that can still fix it.
[[ $# -ge 5 ]] || usage
phase=$3
root=$4
item=$5
shift 5

outcome=pass
summary=''
commit_subject=''
commit_body=''
failure_class=''
failure_reason=''
evidence_lines=()

while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || {
    printf 'write-artifact: %s requires a value\n' "$1" >&2
    exit 2
  }
  case $1 in
    --outcome) outcome=$2 ;;
    --summary) summary=$2 ;;
    --commit-subject) commit_subject=$2 ;;
    --commit-body) commit_body=$2 ;;
    --commit-body-file) commit_body=$(cat -- "$2") ;;
    --failure-class) failure_class=$2 ;;
    --failure-reason) failure_reason=$2 ;;
    --evidence) evidence_lines+=("$2") ;;
    --worktree)
      state_root=$(cd -- "$2" && pwd)
      state_cmd=(git -C "$state_root" -c core.excludesFile=/dev/null)
      ;;
    --evidence-file)
      while IFS= read -r evidence_line; do
        [[ -n $evidence_line ]] && evidence_lines+=("$evidence_line")
      done <"$2"
      ;;
    *)
      printf 'write-artifact: unknown option %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift 2
done

case $phase in
  implement|verify) ;;
  *) printf 'write-artifact: phase must be implement or verify\n' >&2; exit 2 ;;
esac
case $outcome in
  pass|fail) ;;
  *) printf 'write-artifact: outcome must be pass or fail\n' >&2; exit 2 ;;
esac

# The baseline comes from the lock the phase already owns, so the artifact cannot
# disagree with the provenance recorded before any mutation.
[[ -f "$lock_dir/root" && $(<"$lock_dir/root") == "$root" ]] || {
  printf 'write-artifact: workflow %s does not own the repository lock\n' "$root" >&2
  exit 3
}
baseline_sha=$(<"$lock_dir/base")
baseline_sha=${baseline_sha//[$'\r\n']/}

changed_files_json=$(changed_files | jq -R 'select(length > 0)' | jq -s 'sort | unique')
evidence_json=$(printf '%s\n' "${evidence_lines[@]+"${evidence_lines[@]}"}" |
  jq -R 'select(length > 0)' | jq -s '.')
artifact_digest=$(content_digest)

# Backlog task IDs are canonical and supplied directly by the driver.
canonical_id=$item
if [[ -n $commit_body ]]; then
  if ! grep -Fqx "Task: $canonical_id" <<<"$commit_body"; then
    commit_body+=$'\n\nTask: '
    commit_body+="$canonical_id"
  fi
else
  commit_body="Task: $canonical_id"
fi

work_dir="$repo/.cao/work/$root"
mkdir -p "$work_dir"
if [[ $phase == implement ]]; then
  artifact="$work_dir/implementation.json"
else
  artifact="$work_dir/verify.json"
fi
# Built in memory and written only after validation passes. A rejected artifact
# must never reach disk, or the phase reports a usage error while finalization
# still finds the invalid file and fails the whole root on it.
artifact_json=$(jq -n \
  --arg phase "$phase" \
  --arg outcome "$outcome" \
  --arg item "$item" \
  --arg workflow_root "$root" \
  --arg baseline_sha "$baseline_sha" \
  --arg digest "$artifact_digest" \
  --arg summary "$summary" \
  --arg commit_subject "$commit_subject" \
  --arg commit_body "$commit_body" \
  --arg failure_class "$failure_class" \
  --arg failure_reason "$failure_reason" \
  --arg artifact_path ".cao/work/$root/${artifact##*/}" \
  --argjson changed_files "$changed_files_json" \
  --argjson evidence_lines "$evidence_json" \
  '{phase:$phase, status:"complete", outcome:$outcome, item:$item,
    workflow_root:$workflow_root, artifact:$artifact_path,
    baseline_sha:$baseline_sha, digest:$digest, changed_files:$changed_files,
    summary:$summary, commit_subject:$commit_subject, commit_body:$commit_body}
   + (if $phase == "verify" then {evidence_lines:$evidence_lines} else {} end)
   + (if $outcome == "fail"
      then {failure_class:$failure_class, failure_reason:$failure_reason}
      else {} end)')

# Validated here, against the same rules finalization applies, so a contract error
# surfaces in the phase that can still correct it rather than becoming a terminal
# workflow failure three phases later.
validation_error=$(jq -r --arg phase "$phase" '
  [ (if (.item | length) == 0 then "item is empty" else empty end),
    (if (.baseline_sha | test("^[0-9a-f]{40}$") | not) then "baseline_sha is not a 40-character SHA" else empty end),
    (if (.digest | test("^[0-9a-f]{64}$") | not) then "digest is not a 64-character hash" else empty end),
    (if (.summary | length) == 0 then "--summary is required" else empty end),
    (if (.commit_subject | length) == 0 then "--commit-subject is required" else empty end),
    (if (.commit_body | length) == 0 then "--commit-body or --commit-body-file is required" else empty end),
    (if .outcome == "pass" and (.changed_files | length) == 0
     then "a passing phase changed no files" else empty end),
    (if .outcome == "fail" and ((.failure_class | length) == 0 or (.failure_reason | length) == 0)
     then "a failing phase requires --failure-class and --failure-reason" else empty end),
    (if $phase == "verify" and .outcome == "pass" and (any(.evidence_lines[]?; startswith("AC#")) | not)
     then "verify requires at least one --evidence line starting with AC#" else empty end),
    (if $phase == "verify" and .outcome == "pass" and (any(.evidence_lines[]?; startswith("Required gate:")) | not)
     then "verify requires an --evidence line starting with \"Required gate:\"" else empty end)
  ] | join("; ")' <<<"$artifact_json")

if [[ -n $validation_error ]]; then
  printf 'write-artifact: %s\n' "$validation_error" >&2
  exit 4
fi

printf '%s\n' "$artifact_json" >"$artifact"
printf '%s\n' "$artifact"
