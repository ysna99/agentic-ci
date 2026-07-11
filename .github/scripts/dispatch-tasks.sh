#!/usr/bin/env bash
# Stateless auto-task dispatcher.
#
# Reads IMMUTABLE manifests from the working tree (.github/auto-tasks/<slug>/tasks.json),
# derives every task's state from GitHub issues/PRs on each run, and opens at most ONE new
# "@claude" task issue per invocation. It never writes the manifest, never pushes to the
# (protected) default branch, and never merges anything -- that removes the old dispatcher's
# root flaw (committing manifest progress back to a protected branch).
#
# Task<->issue binding: each task carries a unique label  at:<slug>-<id>.
# Per-task derived state:
#   PENDING   - no  at:<slug>-<id>  issue exists yet
#   IN_FLIGHT - that issue exists, is open, and no merged PR has completed it
#   DONE      - a merged PR with head  claude/issue-<N>-*  exists (N = the task's issue number)
#   BLOCKED   - the issue is closed and there is no such merged PR (a human said "no")
#
# BLOCKED stops the chain (we do not barrel past a human's "no"). One task advances per merged PR.
#
# Env:
#   REPO                owner/name             (required)
#   GH_TOKEN            CLAUDE_PR_PAT          (required: issues are opened as a human so claude.yml fires)
#   EVENT               github.event_name      (optional: "pull_request" gets the merge guard below)
#   PR_MERGED           true|false             (optional: only meaningful for a pull_request event)
#   AUTO_TASKS_ENABLED  true|false             (optional: "false" disables the dispatcher)
#   MANIFEST_GLOB       override for tests     (default .github/auto-tasks/*/tasks.json)
set -euo pipefail

REPO="${REPO:?REPO is required}"
: "${GH_TOKEN:?GH_TOKEN (CLAUDE_PR_PAT) is required}"
EVENT="${EVENT:-}"
MANIFEST_GLOB="${MANIFEST_GLOB:-.github/auto-tasks/*/tasks.json}"

if [ "${AUTO_TASKS_ENABLED:-true}" = "false" ]; then
  echo "AUTO_TASKS_ENABLED=false; dispatcher disabled."
  exit 0
fi
# A PR that closed without merging is not a task completion; nothing to advance.
if [ "$EVENT" = "pull_request" ] && [ "${PR_MERGED:-}" != "true" ]; then
  echo "PR closed without merge; nothing to advance."
  exit 0
fi

# --- GitHub state providers (overridable in tests by defining these before sourcing) ---
if ! declare -F merged_heads >/dev/null; then
  # All merged-PR head branch names, newline separated.
  # ponytail: last 200 merged PRs; raise --limit if a chain ever spans >200 merges.
  merged_heads() { gh pr list -R "$REPO" --state merged --limit 200 --json headRefName --jq '.[].headRefName'; }
fi
if ! declare -F issue_for_label >/dev/null; then
  # First issue (any state) carrying a label -> "<number> <OPEN|CLOSED>", or empty.
  issue_for_label() {
    gh issue list -R "$REPO" --label "$1" --state all --json number,state \
      --jq '.[0] | if . == null then empty else "\(.number) \(.state)" end'
  }
fi

MERGED_HEADS="$(merged_heads || true)"
is_done() { printf '%s\n' "$MERGED_HEADS" | grep -qE "^claude/issue-$1(-|\$)"; }

shopt -s nullglob
for MANIFEST in $MANIFEST_GLOB; do
  jq -e '.paused != true' "$MANIFEST" >/dev/null 2>&1 || { echo "Paused, skipping: $MANIFEST"; continue; }
  SLUG="$(jq -r '.slug // "auto-task"' "$MANIFEST")"
  MAXT="$(jq -r '.max_tasks // 0' "$MANIFEST")"
  echo "== $MANIFEST (slug=$SLUG) =="

  # STATE is an indexed array keyed by the integer task id (portable to bash 3.2).
  unset STATE; declare -a STATE=()
  BLOCKED_N=""; INFLIGHT=0; USED=0
  IDS=(); while IFS= read -r x; do IDS+=("$x"); done < <(jq -r '.tasks[].id' "$MANIFEST")

  # Pass 1: derive each task's state.
  for ID in ${IDS[@]+"${IDS[@]}"}; do
    INFO="$(issue_for_label "at:$SLUG-$ID" || true)"
    if [ -z "$INFO" ]; then STATE[$ID]=PENDING; continue; fi
    N="${INFO%% *}"; ISTATE="${INFO##* }"; USED=$((USED+1))
    if is_done "$N"; then STATE[$ID]=DONE
    elif [ "$ISTATE" = "CLOSED" ]; then STATE[$ID]=BLOCKED; [ -z "$BLOCKED_N" ] && BLOCKED_N="$N"
    else STATE[$ID]=IN_FLIGHT; INFLIGHT=$((INFLIGHT+1)); fi
  done

  # A human closed a task issue without a merged PR -> stop dispatching.
  # Deliberately halts EVERY manifest, not just this slug: a human said "no"
  # somewhere, and we don't barrel past that anywhere.
  if [ -n "$BLOCKED_N" ]; then
    echo "Task issue #$BLOCKED_N closed without a merged PR; halting ALL dispatching until resolved."
    MARK="auto-task-dispatcher: chain stopped"
    if ! gh issue view "$BLOCKED_N" -R "$REPO" --json comments --jq '.comments[].body' 2>/dev/null | grep -qF "$MARK"; then
      gh issue comment "$BLOCKED_N" -R "$REPO" --body "$MARK for \`$SLUG\`. This task issue was closed without a merged \`claude/issue-$BLOCKED_N-*\` PR, so it is treated as blocked and no further tasks will be opened -- in ANY manifest -- until it is resolved. Complete or reopen this task (or set \`\"paused\": true\`), then re-run the dispatcher to resume."
    fi
    exit 0
  fi

  # One task in flight at a time (globally).
  if [ "$INFLIGHT" -gt 0 ]; then echo "$INFLIGHT task(s) in flight; not dispatching."; exit 0; fi

  # max_tasks caps total issues ever opened for this manifest.
  if [ "$MAXT" -gt 0 ] && [ "$USED" -ge "$MAXT" ]; then
    echo "max_tasks ($MAXT) reached for $SLUG; nothing more to dispatch."; continue
  fi

  # First PENDING task (manifest order) whose dependencies are all DONE.
  NEXT_ID=""
  for ID in ${IDS[@]+"${IDS[@]}"}; do
    [ "${STATE[$ID]}" = "PENDING" ] || continue
    OK=1
    while IFS= read -r D; do
      [ -z "$D" ] && continue
      [ "${STATE[$D]:-}" = "DONE" ] || { OK=0; break; }
    done < <(jq -r --argjson id "$ID" '.tasks[]|select(.id==$id)|(.depends_on // [])[]' "$MANIFEST")
    if [ "$OK" = "1" ]; then NEXT_ID="$ID"; break; fi
  done
  if [ -z "$NEXT_ID" ]; then
    echo "No dispatchable task in $SLUG (all done or dependencies unmet)."; continue
  fi

  # Check-then-create guard: re-verify the label is still absent right before creating.
  if [ -n "$(issue_for_label "at:$SLUG-$NEXT_ID" || true)" ]; then
    echo "Race: at:$SLUG-$NEXT_ID appeared; skipping."; exit 0
  fi

  TITLE="$(jq -r --argjson id "$NEXT_ID" '.tasks[]|select(.id==$id)|.title' "$MANIFEST")"
  BODY="$(jq -r --argjson id "$NEXT_ID" '.tasks[]|select(.id==$id)|.body' "$MANIFEST")"
  gh label create "auto-task" -R "$REPO" --color 1d76db --description "Auto-dispatched task" --force >/dev/null 2>&1 || true
  gh label create "at:$SLUG-$NEXT_ID" -R "$REPO" --color 5319e7 --description "auto-task $SLUG id $NEXT_ID" --force >/dev/null 2>&1 || true
  ISSUE_BODY="$(printf '@claude %s\n\n<!-- auto-task slug=%s id=%s -->\n\n---\n_Auto-task `%s` (id %s), dispatched by task-dispatcher. Implement on a branch off the default branch; a draft PR opens automatically and a human reviews + merges it._' \
    "$BODY" "$SLUG" "$NEXT_ID" "$SLUG" "$NEXT_ID")"
  URL="$(gh issue create -R "$REPO" --title "[auto-task] $TITLE" --label "auto-task" --label "at:$SLUG-$NEXT_ID" --body "$ISSUE_BODY")"
  echo "Opened $URL for task $NEXT_ID."
  exit 0
done

echo "No manifest had a dispatchable task."
