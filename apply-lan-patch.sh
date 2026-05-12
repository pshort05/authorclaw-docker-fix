#!/usr/bin/env bash
# apply-lan-patch.sh
#
# Reapply the LAN-access patch to gateway/src/index.ts after a fresh `git pull`.
# Tracks an upstream issue: https://github.com/Ckokoski/authorclaw/issues/4
#
# Until the upstream author chooses a direction (e.g. AUTHORCLAW_BIND env var,
# AUTHORCLAW_CORS_ORIGINS env var, or maintaining the localhost-only design),
# this script reapplies four targeted changes to the source tree so the gateway
# is reachable from other hosts on the LAN:
#
#   1. server.listen bind:  127.0.0.1  ->  process.env.AUTHORCLAW_BIND || '0.0.0.0'
#   2. SocketIO CORS:       localhost-only allowlist  ->  '*'
#   3. helmet CSP connectSrc: localhost-only          ->  ['*'] + upgradeInsecureRequests:null
#   4. express CORS:        localhost-only allowlist  ->  '*'
#   5. WebSocket origin:    hard reject non-localhost ->  accept (rely on bind perimeter)
#
# Usage:
#   ./apply-lan-patch.sh           # apply patch (idempotent)
#   ./apply-lan-patch.sh --rebuild # apply + docker compose build + up -d
#   ./apply-lan-patch.sh --check   # report status without changing anything
#
# Exits 0 on success / already-applied, non-zero if any anchor isn't found
# (likely upstream has restructured and the patch needs revisiting).

set -euo pipefail

REPO=/opt/docker-compose/authorclaw/src
FILE="$REPO/gateway/src/index.ts"
COMPOSE_DIR=/opt/docker-compose
SVC=authorclaw

CHECK_ONLY=0
DO_REBUILD=0
for arg in "$@"; do
    case "$arg" in
        --check)   CHECK_ONLY=1 ;;
        --rebuild) DO_REBUILD=1 ;;
        --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ -f "$FILE" ] || { echo "ERROR: $FILE not found"; exit 1; }

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Each transformation is a {test, search, replace} triple.
# `test` is a string that, if present in the file, means the patch is already applied.
# `search` is the exact upstream string to replace.
# `replace` is what to write.
#
# Using literal strings (not regex) for both robustness and clarity.

declare -A APPLIED
NEED_WORK=0

# ---------- 1. server.listen bind ----------
T1_TEST="const host = process.env.AUTHORCLAW_BIND"
T1_SEARCH="    this.server.listen(port, '127.0.0.1', () => {"
T1_REPLACE="    const host = process.env.AUTHORCLAW_BIND || '0.0.0.0';
    this.server.listen(port, host, () => {"

# ---------- 2. SocketIO CORS ----------
T2_TEST="cors: { origin: '*' },"
T2_SEARCH="cors: { origin: ['http://localhost:3847', 'http://127.0.0.1:3847'] },"
T2_REPLACE="cors: { origin: '*' },"

# ---------- 3. helmet CSP connectSrc ----------
T3_TEST='connectSrc: ["'\''self'\''", "*"],'
T3_SEARCH='connectSrc: ["'\''self'\''", "http://localhost:3847", "http://127.0.0.1:3847"],'
T3_REPLACE='connectSrc: ["'\''self'\''", "*"],
          upgradeInsecureRequests: null,'

# ---------- 4. express CORS middleware ----------
T4_TEST="this.app.use(cors({ origin: '*' }));"
T4_SEARCH="this.app.use(cors({ origin: ['http://localhost:3847', 'http://127.0.0.1:3847'] }));"
T4_REPLACE="this.app.use(cors({ origin: '*' }));"

# ---------- 5. WebSocket origin allowlist removal ----------
# Replace the entire 5-line allowlist+disconnect block with a comment line.
T5_TEST="// LAN access: all origins accepted (server binds to 0.0.0.0)"
T5_SEARCH="      const allowed = ['http://localhost:3847', 'http://127.0.0.1:3847'];
      if (origin && !allowed.includes(origin)) {
        this.audit.log('security', 'websocket_rejected', { origin });
        socket.disconnect();
        return;
      }"
T5_REPLACE="      // LAN access: all origins accepted (server binds to 0.0.0.0)"

apply_one() {
    local n="$1" test="$2" search="$3" replace="$4"
    if grep -qF -- "$test" "$FILE"; then
        APPLIED[$n]=already
        log "  [$n] already applied"
        return 0
    fi
    if ! grep -qF -- "$search" "$FILE"; then
        APPLIED[$n]=MISSING
        warn "  [$n] neither test nor search anchor found — upstream may have restructured this section"
        NEED_WORK=1
        return 1
    fi
    if [ "$CHECK_ONLY" = 1 ]; then
        APPLIED[$n]=needs-apply
        log "  [$n] would apply"
        NEED_WORK=1
        return 0
    fi
    # Use Python for safe literal-string replacement (sed gets ugly with multi-line + special chars).
    python3 - "$FILE" "$search" "$replace" <<'PY'
import sys, pathlib
path, search, replace = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
text = p.read_text()
if text.count(search) != 1:
    print(f'EXPECTED exactly 1 occurrence, found {text.count(search)}', file=sys.stderr)
    sys.exit(3)
p.write_text(text.replace(search, replace, 1))
PY
    APPLIED[$n]=applied
    log "  [$n] applied"
}

log "patching $FILE"
log ""
apply_one 1-bind         "$T1_TEST" "$T1_SEARCH" "$T1_REPLACE"
apply_one 2-socketio-cors "$T2_TEST" "$T2_SEARCH" "$T2_REPLACE"
apply_one 3-csp-connect   "$T3_TEST" "$T3_SEARCH" "$T3_REPLACE"
apply_one 4-express-cors  "$T4_TEST" "$T4_SEARCH" "$T4_REPLACE"
apply_one 5-ws-origin     "$T5_TEST" "$T5_SEARCH" "$T5_REPLACE"
log ""

# Summary
log "summary:"
for k in 1-bind 2-socketio-cors 3-csp-connect 4-express-cors 5-ws-origin; do
    log "  $k: ${APPLIED[$k]:-?}"
done

# If any change was MISSING, fail loudly so the human knows to look.
for k in "${!APPLIED[@]}"; do
    [ "${APPLIED[$k]}" = "MISSING" ] && die "one or more anchors missing — upstream changed; review $FILE manually"
done

if [ "$CHECK_ONLY" = 1 ]; then
    if [ "$NEED_WORK" = 1 ]; then
        log "CHECK: patch is INCOMPLETE — re-run without --check to apply"
        exit 4
    fi
    log "CHECK: patch is fully applied"
    exit 0
fi

if [ "$DO_REBUILD" = 1 ]; then
    log ""
    log "rebuild requested — building image and recreating container"
    cd "$COMPOSE_DIR"
    sudo docker compose build "$SVC"
    sudo docker compose up -d --force-recreate "$SVC"
    sleep 5
    log ""
    log "post-rebuild verification:"
    docker ps --filter "name=$SVC" --format '  {{.Names}} {{.Status}}'
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:3847/api/health" || echo "000")
    log "  http://localhost:3847/api/health => $code"
    [ "$code" = "200" ] || die "post-rebuild HTTP check failed (got $code)"
fi

log "done"
