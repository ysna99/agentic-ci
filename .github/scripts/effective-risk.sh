#!/usr/bin/env bash
# Effective risk of an existing PR: the STRICTER of the PR body's declared
# "Risk level:" line and a fresh diff classification (classify-risk.sh), so a
# hand-edited body can never weaken the classifier's floor.
#   Usage: effective-risk.sh <pr-number>
#   Env (both REQUIRED):
#     REPO=owner/repo
#     GH_TOKEN=<token with contents:read + pull_requests:read>
#   Prints exactly one of: simple | complex | human-required
#
# Single source of truth for codex-bridge.yml, risk-label.yml and
# auto-merge.yml, which previously carried three copy-pasted versions of this
# computation that could drift apart.
#
# SECURITY: like classify-risk.sh, only ever invoke the copy of this script
# from a trusted ref (the default branch), never from a PR checkout.
set -euo pipefail

PR="${1:?pr number required}"
: "${REPO:?REPO env (owner/repo) required}"
: "${GH_TOKEN:?GH_TOKEN env required}"

PR_JSON="$(gh api "repos/${REPO}/pulls/${PR}")"
BASE_SHA="$(printf '%s' "$PR_JSON" | jq -r '.base.sha')"
HEAD_SHA="$(printf '%s' "$PR_JSON" | jq -r '.head.sha')"

# Risk declared in the PR body (case-insensitive, optional backticks).
BODY_RISK="$(printf '%s' "$PR_JSON" | jq -r '.body // ""' \
  | grep -ioE 'risk level:[[:space:]]*`?(simple|complex|human-required)`?' \
  | head -n 1 | grep -ioE '(simple|complex|human-required)' \
  | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"

# A missing classifier means a broken checkout -> fail closed, never open.
DIFF_RISK="human-required"
if [ -f "$(dirname "$0")/classify-risk.sh" ]; then
  DIFF_RISK="$(bash "$(dirname "$0")/classify-risk.sh" "$BASE_SHA" "$HEAD_SHA" || echo human-required)"
fi

rank() { case "$1" in human-required) echo 3;; complex) echo 2;; simple) echo 1;; *) echo 0;; esac; }
if [ "$(rank "$DIFF_RISK")" -ge "$(rank "$BODY_RISK")" ]; then
  echo "$DIFF_RISK"
else
  echo "$BODY_RISK"
fi
