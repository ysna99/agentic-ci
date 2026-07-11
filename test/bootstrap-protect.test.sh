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
    if [ "${T_MISS_SECRET:-}" = "1" ]; then out='{"secrets":[{"name":"ANTHROPIC_API_KEY"}]}'
    else out='{"secrets":[{"name":"ANTHROPIC_API_KEY"},{"name":"CLAUDE_PR_PAT"}]}'; fi ;;
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
if out="$(T_MISS_SECRET=1 bash "$ROOT/bootstrap/protect.sh" o/r --verify 2>&1)"; then
  echo "FAIL  verify: missing secret should exit non-zero"; fails=$((fails+1))
elif printf '%s' "$out" | grep -q 'FAIL  secret CLAUDE_PR_PAT'; then
  echo "PASS  verify: missing secret detected"
else
  echo "FAIL  verify: missing secret detected"; printf '%s\n' "$out"; fails=$((fails+1))
fi

echo; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
