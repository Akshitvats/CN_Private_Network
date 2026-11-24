#!/bin/bash
# smoke-test.sh - quick end-to-end check from any CLIENT Mac:
#   DNS (both resolvers + system resolver) -> HTTPS with a VERIFIED certificate
#   (no -k) -> load balancing -> caching -> port 80 redirect.
# Usage: scripts/smoke-test.sh          (for layer-by-layer fault finding use scripts/diagnose.sh)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"
PASS=0; FAIL=0
check() { if eval "$2" >/dev/null 2>&1; then echo "  ${G}PASS${N} $1"; PASS=$((PASS+1)); else echo "  ${R}FAIL${N} $1"; FAIL=$((FAIL+1)); fi; }

echo "${B}== 1. DNS${N}"
echo "  primary $DNS1_IP ($MAC1_NAME): $(dig @"$DNS1_IP" "$APP" +short +time=2 +tries=1 | tail -1)   TTL $(dig +nocmd @"$DNS1_IP" "$APP" +noall +answer +time=2 +tries=1 | awk '/IN[[:space:]]+A/{print $2}')"
echo "  backup  $DNS2_IP ($MAC2_NAME): $(dig @"$DNS2_IP" "$APP" +short +time=2 +tries=1 | tail -1)"
SYS="$(sysresolve "$APP")"
echo "  this Mac's system resolver: ${SYS:-<none>}"
check "primary resolver answers $APP" "[ \"\$(dig @$DNS1_IP $APP +short +time=2 +tries=1)\" = $APP_RECORD_IP ]"
check "backup resolver answers $APP"  "[ \"\$(dig @$DNS2_IP $APP +short +time=2 +tries=1)\" = $APP_RECORD_IP ]"
check "system resolver resolves $APP" "[ -n \"$SYS\" ]"
[ -n "$SYS" ] || { echo "  Set this Mac's DNS to the team resolvers: sudo scripts/phase2/client-setup.sh"; exit 1; }

echo "${B}== 2. HTTPS through the edge (certificate verified by the system trust store, no -k), 6 requests${N}"
SEEN=""
for _ in 1 2 3 4 5 6; do
    line="$(curl -sS --max-time 8 -D - -o /dev/null "https://$APP/api/status" 2>&1 | tr -d '\r' \
        | awk 'NR==1{s=$1" "$2} tolower($1)=="x-backend:"{b=$2} tolower($1)=="x-edge:"{e=$2} END{printf "%s  backend=%s  edge=%s", s, b, e}')"
    echo "  $line"; SEEN+="$line "
done
check "HTTP/2 200 with a verified certificate" "curl -sf -o /dev/null --http2 https://$APP/api/status"
check "both backends answer (round robin)" "[[ \"$SEEN\" == *backend=A* && \"$SEEN\" == *backend=B* ]]"

echo "${B}== 3. Caching headers + conditional request${N}"
curl -sSI "https://$APP/api/cache" | grep -iE '^HTTP|cache-control|etag' | tr -d '\r' | sed 's/^/  /'
check "If-None-Match -> 304 Not Modified" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'If-None-Match: \"cn-cache-v1\"' https://$APP/api/cache)\" = 304 ]"

echo "${B}== 4. Port 80 redirects to HTTPS${N}"
echo "  $(curl -s -o /dev/null -w 'http://%{url.host} -> %{http_code} %{redirect_url}' "http://$APP/api/status")"
check "http:// -> 301 https://" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://$APP/api/status)\" = 301 ]"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
