#!/usr/bin/env bash
# Offline check of protect.sh --verify: runs the REAL script against a fake
# `gh` that answers each API path from fixtures, and asserts the pass/fail
# verdicts. Apply mode is thin idempotent PUTs and is not exercised.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: emulate the `gh api` calls protect.sh --verify makes.
[ "$1" = "api" ] || exit 0
shift
P=""; JQ=""; RAW=0
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in *raw*) RAW=1 ;; esac; shift 2 ;;
    --jq) JQ="$2"; shift 2 ;;
    -X|--input) shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift ;;
  esac
done
P="${P%%\?*}"
out=""
case "$P" in
  repos/o/r/branches/main/protection)
    out='{"enforce_admins":{"enabled":true},"required_status_checks":{"checks":[{"context":"checks"}]}}' ;;
  repos/o/r/contents/.github/auto/sensitive-paths.txt)
    if [ "$RAW" = 1 ]; then printf '# boundaries\nstripe\n^CLAUDE\\.md$\n'; exit 0; fi
    out='{"name":"sensitive-paths.txt"}' ;;
  repos/o/r/contents/*)
    out="{\"name\":\"$(basename "$P")\"}" ;;
  repos/o/r/actions/secrets)
    # T_SECRETS: space-separated secret names present (default: API key + PAT).
    out="$(printf '%s\n' ${T_SECRETS:-ANTHROPIC_API_KEY CLAUDE_PR_PAT} | jq -R '{name: .}' | jq -s '{secrets: .}')" ;;
  repos/o/r/actions/variables)
    out='{"variables":[{"name":"MAX_FIX_ROUNDS"}]}' ;;
  repos/o/r)
    out='{"default_branch":"main"}' ;;
  *) exit 1 ;;
esac
if [ -n "$JQ" ]; then printf '%s' "$out" | jq -r "$JQ"; else printf '%s' "$out"; fi
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

fails=0
# All preconditions present -> exits 0 and prints the handoff line.
if out="$(bash "$ROOT/bootstrap/protect.sh" o/r --verify 2>&1)" \
   && printf '%s' "$out" | grep -q 'ALL PRECONDITIONS PASS'; then
  echo "PASS  verify: all preconditions green"
else
  echo "FAIL  verify: all preconditions green"; printf '%s\n' "$out"; fails=$((fails+1))
fi
# Active boundary lines counted from raw content (2 non-comment lines).
if printf '%s' "$out" | grep -q 'declares 2 boundary pattern(s)'; then
  echo "PASS  verify: boundary lines counted"
else
  echo "FAIL  verify: boundary lines counted"; fails=$((fails+1))
fi
# A missing secret -> exit 1 and a FAIL line naming it with the fix command.
if out="$(T_SECRETS="ANTHROPIC_API_KEY" bash "$ROOT/bootstrap/protect.sh" o/r --verify 2>&1)"; then
  echo "FAIL  verify: missing secret should exit non-zero"; fails=$((fails+1))
elif printf '%s' "$out" | grep -q 'FAIL  secret CLAUDE_PR_PAT'; then
  echo "PASS  verify: missing secret detected"
else
  echo "FAIL  verify: missing secret detected"; printf '%s\n' "$out"; fails=$((fails+1))
fi
# Subscription token alone satisfies Claude auth.
if out="$(T_SECRETS="CLAUDE_CODE_OAUTH_TOKEN CLAUDE_PR_PAT" bash "$ROOT/bootstrap/protect.sh" o/r --verify 2>&1)" \
   && printf '%s' "$out" | grep -q 'PASS  Claude auth: CLAUDE_CODE_OAUTH_TOKEN'; then
  echo "PASS  verify: subscription token accepted"
else
  echo "FAIL  verify: subscription token accepted"; printf '%s\n' "$out"; fails=$((fails+1))
fi
# No Claude auth secret -> exit 1 and a FAIL line naming both options.
if out="$(T_SECRETS="CLAUDE_PR_PAT" bash "$ROOT/bootstrap/protect.sh" o/r --verify 2>&1)"; then
  echo "FAIL  verify: missing Claude auth should exit non-zero"; fails=$((fails+1))
elif printf '%s' "$out" | grep -q 'FAIL  Claude auth secret.*CLAUDE_CODE_OAUTH_TOKEN.*ANTHROPIC_API_KEY'; then
  echo "PASS  verify: missing Claude auth detected"
else
  echo "FAIL  verify: missing Claude auth detected"; printf '%s\n' "$out"; fails=$((fails+1))
fi
# Both set -> still passes, but warns that the API key wins (billed).
if out="$(T_SECRETS="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDE_PR_PAT" bash "$ROOT/bootstrap/protect.sh" o/r --verify 2>&1)" \
   && printf '%s' "$out" | grep -q 'both secrets set -- ANTHROPIC_API_KEY takes precedence'; then
  echo "PASS  verify: both auth secrets flagged"
else
  echo "FAIL  verify: both auth secrets flagged"; printf '%s\n' "$out"; fails=$((fails+1))
fi

echo; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
