#!/usr/bin/env bash
# Deterministically classify a PR's risk from its changed files.
#   Usage: classify-risk.sh <base> <head>          (base/head = ref or SHA)
#   Env (both REQUIRED):
#     REPO=owner/repo
#     GH_TOKEN=<token with contents:read>           # used by `gh api`
#   Prints exactly one of: simple | complex | human-required
#   Fails safe to human-required on an empty/unknown diff.
#
# SECURITY: only ever invoke the copy of this script from a trusted ref
# (the default branch), never from a PR checkout -- a PR could otherwise edit
# its own classifier.
set -euo pipefail

BASE="${1:?base ref/sha required}"
HEAD="${2:?head ref/sha required}"
: "${REPO:?REPO env (owner/repo) required}"
: "${GH_TOKEN:?GH_TOKEN env (contents:read) required}"

# URL-encode each ref so the compare path is robust to slashes (e.g.
# claude/issue-123-foo) and any other URL-unsafe characters in a branch name.
# The "..." basehead separator stays literal between the two encoded refs.
enc() { jq -rn --arg s "$1" '$s | @uri'; }
CMP="$(gh api "repos/${REPO}/compare/$(enc "$BASE")...$(enc "$HEAD")" 2>/dev/null || true)"
[ -n "$CMP" ] || { echo "human-required"; exit 0; }

# The compare endpoint returns the changed-file list only on the first page and
# caps it at 300 files for the whole comparison, so a larger diff could hide a
# sensitive path outside the visible set. Fail closed when we hit the cap.
# https://docs.github.com/en/rest/commits/commits#compare-two-commits
NFILES="$(printf '%s' "$CMP" | jq '.files | length')"
if [ "${NFILES:-0}" -ge 300 ]; then
  echo "human-required"; exit 0
fi

# Classify both the new path AND the renamed-from path (previous_filename): a
# rename OUT of a sensitive path must still count as sensitive.
FILES="$(printf '%s' "$CMP" | jq -r '.files[] | .filename, (.previous_filename // empty)')"
[ -n "$FILES" ] || { echo "human-required"; exit 0; }

# Sensitive paths -> always human-required. A universal BASE covers boundaries
# true for any repo: CI/automation config, dependency manifests+lockfiles across
# common ecosystems (npm/pip/go/cargo/gem), dotenv files, and the keywords
# secret/auth/jwt/admin/payment/migration. Repo-specific boundaries are declared
# in .github/auto/sensitive-paths.txt (one extended-regex fragment per line;
# '#' comments and blank lines ignored) and OR-ed in. Absent/empty file -> base
# only (still safe). SECURITY: that config, like this script, is read only from
# the trusted default branch -- a PR must not weaken its own classification.
SENSITIVE_BASE='(^\.github/|(^|/)(package(-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|requirements\.txt|Pipfile(\.lock)?|go\.(mod|sum)|Cargo\.(toml|lock)|Gemfile(\.lock)?)$|(^|/)\.env|secret|auth|jwt|admin|payment|migration)'
EXTRA="$(sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$(dirname "$0")/../auto/sensitive-paths.txt" 2>/dev/null | awk 'NF' | paste -sd'|' - || true)"
if [ -n "$EXTRA" ]; then SENSITIVE="(${SENSITIVE_BASE}|${EXTRA})"; else SENSITIVE="$SENSITIVE_BASE"; fi
# grep rc: 0=match, 1=no match, >=2=error (e.g. a malformed regex line in
# sensitive-paths.txt). An error must fail CLOSED: inside a bare `if` it would
# read as "no match" and one bad config line would silently disable the whole
# sensitive check, built-in BASE patterns included.
set +e
printf '%s\n' "$FILES" | grep -qiE "$SENSITIVE"
GREP_RC=$?
set -e
if [ "$GREP_RC" -ne 1 ]; then
  echo "human-required"; exit 0
fi

# Size-based: use the real changed-file count (NFILES, not the rename-doubled list).
CHANGES="$(printf '%s' "$CMP" | jq -r '[.files[] | (.additions + .deletions)] | add // 0')"
if [ "${NFILES:-0}" -gt 5 ] || [ "${CHANGES:-0}" -gt 150 ]; then
  echo "complex"
else
  echo "simple"
fi
