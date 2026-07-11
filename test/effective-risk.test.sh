#!/usr/bin/env bash
# Offline check of effective-risk.sh: body-line extraction and the
# stricter-of(body, diff) rule that codex-bridge, risk-label and auto-merge all
# gate on. Runs the REAL scripts against a path-aware fake `gh`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# fake gh: `gh api .../pulls/<n>` -> $PR_FIXTURE, `gh api .../compare/...` -> $CMP_FIXTURE
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
  */compare/*) cat "$CMP_FIXTURE" ;;
  */pulls/*)   cat "$PR_FIXTURE" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/scripts" "$TMP/auto"
cp "$ROOT/.github/scripts/effective-risk.sh" "$ROOT/.github/scripts/classify-risk.sh" "$TMP/scripts/"

# compare fixtures: one small doc file -> simple; one big file -> complex
printf '{"files":[{"filename":"README.md","additions":2,"deletions":0}]}' >"$TMP/cmp-simple.json"
printf '{"files":[{"filename":"src/lib/util.ts","additions":200,"deletions":0}]}' >"$TMP/cmp-complex.json"

pr_fixture() { # <body> -> writes $TMP/pr.json
  jq -n --arg body "$1" '{base:{sha:"b"},head:{sha:"h"},body:$body}' >"$TMP/pr.json"
}

fails=0
check() { # <label> <cmp-fixture> <expected>   (pr.json prepared by caller)
  local label="$1" cmp="$2" want="$3" got
  got="$(PR_FIXTURE="$TMP/pr.json" CMP_FIXTURE="$TMP/$cmp" REPO=o/r GH_TOKEN=t \
    bash "$TMP/scripts/effective-risk.sh" 7)"
  if [ "$got" = "$want" ]; then echo "PASS  $label ($got)"; else echo "FAIL  $label: want=$want got=$got"; fails=$((fails+1)); fi
}

pr_fixture 'Automated draft PR.'
check "no body line -> diff wins"           cmp-simple.json  simple

pr_fixture $'Summary.\n\nRisk level: human-required\n'
check "stricter body beats simple diff"     cmp-simple.json  human-required

pr_fixture $'Summary.\n\nrisk level: `simple`\n'
check "weaker body cannot beat complex diff" cmp-complex.json complex

echo; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
