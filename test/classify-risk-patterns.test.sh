#!/usr/bin/env bash
# Offline check of classify-risk.sh's denylist: universal BASE + per-repo EXTRA
# (from auto/sensitive-paths.txt) + size buckets. Runs the REAL script against a
# fake `gh` that returns fixture compare JSON, so there is no logic to drift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/.github/scripts/classify-risk.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# fake gh: `gh api <compare-path>` -> emit the fixture named by $GH_FIXTURE.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "api" ] && cat "$GH_FIXTURE" || exit 0
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Two script copies with the right relative layout (script reads ../auto/...):
#  WITHCFG has a sensitive-paths.txt with a repo-specific pattern; NOCFG has none.
for d in WITHCFG NOCFG; do mkdir -p "$TMP/$d/scripts" "$TMP/$d/auto"; cp "$SCRIPT" "$TMP/$d/scripts/"; done
printf '(^|/)src/app/api/   # server API routes\n# a comment line\n' >"$TMP/WITHCFG/auto/sensitive-paths.txt"

# build a compare-JSON fixture from "path:add:del" specs
fixture() { local out='{"files":['; local first=1 p; for spec in "$@"; do
    IFS=: read -r p a del <<<"$spec"
    [ $first -eq 1 ] || out+=','; first=0
    out+="{\"filename\":\"$p\",\"additions\":${a:-1},\"deletions\":${del:-0}}"
  done; out+=']}'; printf '%s' "$out"; }

fails=0
check() { # <label> <scriptdir> <expected> <spec...>
  local label="$1" sdir="$2" want="$3"; shift 3
  printf '%s' "$(fixture "$@")" >"$TMP/fix.json"
  local got; got="$(GH_FIXTURE="$TMP/fix.json" REPO=o/r GH_TOKEN=t bash "$TMP/$sdir/scripts/classify-risk.sh" base head)"
  if [ "$got" = "$want" ]; then echo "PASS  $label ($got)"; else echo "FAIL  $label: want=$want got=$got"; fails=$((fails+1)); fi
}

# EXTRA (repo-specific) match
check "extra: src/app/api"        WITHCFG human-required "src/app/api/route.ts:2:0"
# BASE matches, cross-ecosystem
check "base: package.json"        WITHCFG human-required "package.json:2:0"
check "base: requirements.txt"    WITHCFG human-required "app/models.py:2:0" "requirements.txt:1:0"
check "base: .env file"           WITHCFG human-required "config/.env.local:1:0"
check "base: keyword payment"     WITHCFG human-required "src/lib/payment.ts:1:0"
# non-sensitive size buckets
check "simple: one small doc"     WITHCFG simple         "README.md:2:0"
check "complex: >5 files"         WITHCFG complex        "docs/a.md:1:0" "docs/b.md:1:0" "docs/c.md:1:0" "docs/d.md:1:0" "docs/e.md:1:0" "docs/f.md:1:0"
check "complex: >150 lines"       WITHCFG complex        "src/lib/util.ts:200:0"
# design proof: without the repo config, the api boundary is NOT protected
check "no-config: api -> simple"  NOCFG   simple         "src/app/api/route.ts:2:0"

echo; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
