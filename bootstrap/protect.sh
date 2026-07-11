#!/usr/bin/env bash
# One-shot arming + verification of the brownfield preconditions on a freshly
# bootstrapped repo (see skills/bootstrap-project). Run from the agentic-ci
# checkout; this script is NOT copied into consumer repos.
#
#   Usage: protect.sh <owner/repo> [--branch <name>] [--checks <ctx1,ctx2>] [--verify]
#
#   Default:   arm branch protection (required checks + "admins cannot bypass")
#              and set MAX_FIX_ROUNDS, then verify everything below.
#   --verify:  verification only -- re-run after finishing the manual steps
#              (secrets, Codex app) until it prints ALL PRECONDITIONS PASS.
#
# Needs `gh` authenticated as an admin of the target repo.
set -euo pipefail

R=""; BRANCH=""; CHECKS="checks"; VERIFY_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --checks) CHECKS="$2"; shift 2 ;;
    --verify) VERIFY_ONLY=1; shift ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) R="$1"; shift ;;
  esac
done
[ -n "$R" ] || { echo "usage: protect.sh <owner/repo> [--branch b] [--checks c1,c2] [--verify]" >&2; exit 2; }
BRANCH="${BRANCH:-$(gh api "repos/$R" --jq .default_branch)}"

if [ "$VERIFY_ONLY" -eq 0 ]; then
  echo "== Arming $R@$BRANCH (required checks: $CHECKS) =="
  # enforce_admins is load-bearing: the merging PAT usually belongs to an admin,
  # and without it the merge API lets admins past red required checks.
  jq -n --arg checks "$CHECKS" '{
    required_status_checks: { strict: true,
      checks: ($checks | split(",") | map({context: .})) },
    enforce_admins: true,
    required_pull_request_reviews: null,
    restrictions: null,
    allow_force_pushes: false,
    allow_deletions: false
  }' | gh api -X PUT "repos/$R/branches/$BRANCH/protection" --input - >/dev/null
  echo "Branch protection set (admins cannot bypass red checks)."

  gh variable set MAX_FIX_ROUNDS --body 3 -R "$R"
  echo "MAX_FIX_ROUNDS=3 set. AUTO_MERGE_ENABLED deliberately NOT set: arm it"
  echo "by hand at the stage-3 maturity checkpoint (see the README stage table)."
fi

echo
echo "== Verifying brownfield preconditions on $R@$BRANCH =="
fails=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fails=$((fails+1)); }

# Branch protection: present, admins cannot bypass, at least one required check.
PROT="$(gh api "repos/$R/branches/$BRANCH/protection" 2>/dev/null || true)"
if [ -n "$PROT" ] && [ "$(printf '%s' "$PROT" | jq -r '.enforce_admins.enabled' 2>/dev/null)" = "true" ]; then
  ok "branch protection with enforce_admins"
else
  bad "branch protection with enforce_admins"
fi
NCHECKS="$(printf '%s' "$PROT" | jq '[.required_status_checks.checks[]?] | length' 2>/dev/null || echo 0)"
if [ "${NCHECKS:-0}" -gt 0 ]; then ok "required status checks ($NCHECKS)"; else bad "required status checks"; fi

# The files the engine stands on, present on the default branch.
have() { gh api "repos/$R/contents/$1?ref=$BRANCH" --jq .name >/dev/null 2>&1; }
for f in CLAUDE.md \
         .github/auto/sensitive-paths.txt \
         .github/scripts/classify-risk.sh \
         .github/scripts/effective-risk.sh \
         .github/scripts/dispatch-tasks.sh \
         .github/workflows/claude.yml \
         .github/workflows/codex-bridge.yml \
         .github/workflows/risk-label.yml \
         .github/workflows/auto-merge.yml \
         .github/workflows/task-dispatcher.yml; do
  if have "$f"; then ok "$f"; else bad "$f"; fi
done

# Trust boundaries actually declared (at least one active, non-comment line).
NLINES="$(gh api -H "Accept: application/vnd.github.raw" \
  "repos/$R/contents/.github/auto/sensitive-paths.txt?ref=$BRANCH" 2>/dev/null \
  | sed 's/#.*//' | awk 'NF' | wc -l | tr -d ' ')"
if [ "${NLINES:-0}" -gt 0 ]; then
  ok "sensitive-paths.txt declares $NLINES boundary pattern(s)"
else
  bad "sensitive-paths.txt declares at least one boundary (a greenfield repo must declare its own)"
fi

# Secrets and variables the workflows need.
SECRETS="$(gh api "repos/$R/actions/secrets" --jq '.secrets[].name' 2>/dev/null || true)"
for s in ANTHROPIC_API_KEY CLAUDE_PR_PAT; do
  if printf '%s\n' "$SECRETS" | grep -qx "$s"; then ok "secret $s"; else bad "secret $s   (gh secret set $s -R $R)"; fi
done
VARS="$(gh api "repos/$R/actions/variables" --jq '.variables[].name' 2>/dev/null || true)"
if printf '%s\n' "$VARS" | grep -qx MAX_FIX_ROUNDS; then ok "variable MAX_FIX_ROUNDS"; else bad "variable MAX_FIX_ROUNDS"; fi

echo
echo "Not script-verifiable -- confirm by hand:"
echo "  - the official Codex GitHub review app is installed on $R; after its"
echo "    first review, check the bot login matches CODEX_BOT_LOGIN (default"
echo "    chatgpt-codex-connector[bot]) and set the repo variable if not."
echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PRECONDITIONS PASS -- $R is now a brownfield repo; the engine can run."
else
  echo "$fails precondition(s) failing. Finish the items above, then re-run:"
  echo "  bash bootstrap/protect.sh $R --verify"
  exit 1
fi
