#!/bin/bash
# diagnose.sh - Extension F: systematic, layer-by-layer fault isolation.
# Run on ANY client Mac (no sudo). It checks bottom-up and STOPS at the first
# layer that fails, printing the likely cause and the next command to run.
#
#   scripts/diagnose.sh                   diagnose https://app.teamX.test/api/status
#   scripts/diagnose.sh api.teamX.test    another name
#   DEEP=1 scripts/diagnose.sh            also test the edge -> backend hop over SSH
#
#   L1 client network -> L2 DNS -> L3 IP reachability -> L4 TCP port
#   -> L5 TLS -> L6 HTTP via the edge -> L7 edge -> backends (load balancing)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"
HOST="${1:-$APP}"; PORT="${PORT:-443}"; P="/api/status"
TMPB="$(mktemp)"; trap 'rm -f "$TMPB"' EXIT

ok()   { echo "  ${G}OK${N}    $*"; }
bad()  { echo "  ${R}FAIL${N}  $*"; }
warn() { echo "  ${Y}WARN${N}  $*"; }
hdr()  { echo; echo "${B}[$1] $2${N}"; }
verdict() { echo; echo "${R}${B}>>> FIRST FAILING LAYER: $1${N}"; echo "    likely cause: $2"; echo "    next step:    $3"; exit 1; }

echo "Diagnosing https://$HOST:$PORT$P   ($(date '+%F %T') from $(hostname -s))"

# ---------------------------------------------------------------- L1
hdr L1 "Client network (interface, IP, gateway)"
IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"; IF="${IF:-en0}"
IP="$(ipconfig getifaddr "$IF" 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || true)"
GW="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
[ -n "$IP" ] && ok "$IF has $IP, gateway ${GW:-?}" || verdict "L1 client network" "Wi-Fi down / no DHCP lease" "reconnect Wi-Fi; ipconfig getifaddr en0"
for v in DNS1_IP DNS2_IP EDGE1_IP; do
    [[ "${!v%.*.*}" == "${IP%.*.*}" ]] || { warn "team.env $v=${!v} is not in this Mac's network ($IP) - did DHCP change the IPs? (scripts/update-ips.sh)"; break; }
done

# ---------------------------------------------------------------- L2
hdr L2 "DNS - which servers does this client use, and do they answer?"
SERVERS="$( { networksetup -getdnsservers Wi-Fi 2>/dev/null; scutil --dns | awk '/nameserver\[/{print $3}'; } | grep -E '^[0-9a-f.:]+$' | awk '!s[$0]++' | xargs)"
echo "  system resolvers: ${SERVERS:-none}"
[[ " $SERVERS " == *" $DNS1_IP "* ]] || warn "primary team DNS $DNS1_IP ($MAC1_NAME) is not configured on this client"
[[ " $SERVERS " == *" $DNS2_IP "* ]] || warn "backup team DNS $DNS2_IP ($MAC2_NAME) is not configured on this client"
A1="$(dig @"$DNS1_IP" "$HOST" +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)"
A2="$(dig @"$DNS2_IP" "$HOST" +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)"
[ -n "$A1" ] && ok "primary $DNS1_IP ($MAC1_NAME): $HOST -> $A1" || bad "primary $DNS1_IP ($MAC1_NAME) gives no answer"
[ -n "$A2" ] && ok "backup  $DNS2_IP ($MAC2_NAME): $HOST -> $A2" || bad "backup  $DNS2_IP ($MAC2_NAME) gives no answer"
SYS="$(sysresolve "$HOST")"
[ -n "$SYS" ] && ok "system resolver (what curl/browsers use): $HOST -> $SYS" || bad "system resolver cannot resolve $HOST"
[ -n "$A1" ] && [ -n "$A2" ] && [ "$A1" != "$A2" ] && warn "primary and backup DISAGREE ($A1 vs $A2) - zone out of sync"
[ -z "$SYS" ] && [ -z "$A1$A2" ] && verdict "L2 DNS (servers)" "dnsmasq is stopped on BOTH resolvers, or the record name is wrong" "ssh to Mac 1/2: ~/cn-project/bin/cn.sh dns status; check ~/cn-project/dnsmasq/teamX.hosts"
[ -z "$SYS" ] && verdict "L2 DNS (client config)" "this client is not using the team DNS servers" "sudo scripts/phase2/client-setup.sh  (or System Settings > Network > DNS)"
TARGET="$SYS"; NOT_EDGE=0
[[ " $EDGE1_IP $EDGE2_IP " == *" $TARGET "* ]] || NOT_EDGE=1
[ $NOT_EDGE = 0 ] && ok "$TARGET is an edge ($(who_ip "$TARGET"))" \
                  || warn "$HOST resolves to $TARGET ($(who_ip "$TARGET")), which is NOT an edge ($EDGE1_IP/$EDGE2_IP) - wrong record?"
TTLV="$(dig +nocmd @"$DNS1_IP" "$HOST" +noall +answer 2>/dev/null | awk '/IN[[:space:]]+A/{print $2}' | head -1)"
[ -n "$TTLV" ] && echo "  record TTL: ${TTLV}s (a stale client cache lasts at most this long)"

# ---------------------------------------------------------------- L3
hdr L3 "IP reachability to $TARGET"
if ping -c 1 -t 2 "$TARGET" >/dev/null 2>&1 || nc -z -G 2 "$TARGET" 22 2>/dev/null; then ok "$TARGET is reachable (ICMP/TCP)"
else verdict "L3 IP / network" "$TARGET does not answer at all (host off, wrong IP in DNS, different Wi-Fi)" "ping $TARGET; dig $HOST; check team.env IPs"; fi

# ---------------------------------------------------------------- L4
hdr L4 "TCP connect to $TARGET:$PORT"
T0=$(date +%s)
if nc -z -G 4 "$TARGET" "$PORT" 2>/dev/null; then ok "TCP $PORT open (3-way handshake completed)"
else
    DT=$(( $(date +%s) - T0 ))
    if [ $DT -ge 3 ]; then verdict "L4 TCP (filtered)" "SYN got no answer - a firewall is dropping packets to :$PORT" "check pf on $(who_ip "$TARGET") (sudo pfctl -sr); right port?"
    elif [ $NOT_EDGE = 1 ]; then verdict "L2 DNS (wrong record) - seen at L4" "$HOST resolves to $TARGET ($(who_ip "$TARGET")), not an edge, and nothing listens on :$PORT there" "fix the record on BOTH resolvers: cn.sh dns-record $EDGE1_IP (then wait the TTL or flush the client cache)"
    else verdict "L4 TCP (refused)" "host is up but nothing listens on :$PORT - nginx stopped or on another port" "on $(who_ip "$TARGET"): ~/cn-project/bin/cn.sh edge status; lsof -nP -iTCP -sTCP:LISTEN"; fi
fi

# ---------------------------------------------------------------- L5
hdr L5 "TLS handshake + certificate validation"
TLS="$(echo | openssl s_client -connect "$TARGET:$PORT" -servername "$HOST" -CAfile "$CA" -verify_return_error -verify_hostname "$HOST" 2>&1)"
PROTO="$(grep -m1 -E 'Protocol *:|New, TLS' <<<"$TLS" | xargs)"
if grep -q "Verify return code: 0" <<<"$TLS"; then
    ok "handshake OK ($PROTO); certificate chains to the team CA and matches $HOST"
    openssl x509 -noout -subject -ext subjectAltName -enddate <<<"$TLS" 2>/dev/null | grep -vE '^X509v3' | sed 's/^ */        /'
else
    REASON="$(grep -m1 -E 'verify error|alert|errno|unable|wrong version' <<<"$TLS")"
    CN_NAME="$(openssl x509 -noout -subject <<<"$TLS" 2>/dev/null)"
    verdict "L5 TLS" "${REASON:-certificate does not match $HOST} ${CN_NAME:+[server sent: $CN_NAME]} (wrong/expired cert, name not in SAN, untrusted CA, or plain HTTP on 443)" "openssl s_client -connect $TARGET:$PORT -servername $HOST; check ssl_certificate in ~/cn-project/nginx/cn-project.conf"
fi
curl -s -o /dev/null --max-time 5 "https://$HOST:$PORT/edge-health" || warn "the macOS trust store rejects the cert (curl without --cacert failed) - run client-setup.sh to trust the team CA"

# ---------------------------------------------------------------- L6
hdr L6 "HTTP through the edge"
OUT="$(curl -s --cacert "$CA" --max-time 8 -D - -o "$TMPB" "https://$HOST:$PORT$P" 2>&1)"; RC=$?
CODE="$(awk 'NR==1{print $2}' <<<"$OUT")"
EDGE="$(awk 'tolower($1)=="x-edge:"{print $2}' <<<"$OUT" | tr -d '\r')"
BACK="$(awk 'tolower($1)=="x-backend:"{print $2}' <<<"$OUT" | tr -d '\r')"
case "$CODE" in
    200) ok "HTTP 200 from edge=$EDGE backend=$BACK   body: $(head -c 120 "$TMPB")" ;;
    502|504) bad "HTTP $CODE from edge=$EDGE: the edge works, the BACKENDS do not answer it"
             verdict "L7 edge -> backend" "both backends down, wrong upstream IP/port in nginx, or the backend firewall blocks the edge" "Akshit's Mac: cn.sh backend status; Krishna's Mac: curl http://$BACKEND_A/api/status; tail ~/cn-project/logs/nginx-error.log" ;;
    404) verdict "L6 HTTP (routing)" "nginx answered 404 - server_name / location mismatch" "check server_name in cn-project.conf" ;;
    "")  verdict "L6 HTTP" "no HTTP response (curl exit $RC)" "curl -v https://$HOST$P" ;;
    *)   bad "HTTP $CODE"; verdict "L6 HTTP" "unexpected status $CODE" "curl -v https://$HOST$P; check nginx + backend logs" ;;
esac

# ---------------------------------------------------------------- L7
hdr L7 "Load balancing / backend health (6 requests)"
SEEN=""
for _ in 1 2 3 4 5 6; do
    b="$(curl -s --cacert "$CA" --max-time 5 -D - -o /dev/null "https://$HOST:$PORT$P" | awk 'tolower($1)=="x-backend:"{print $2}' | tr -d '\r')"
    SEEN+="${b:-?} "
done
echo "  backends seen: $SEEN"
if [[ "$SEEN" == *A* && "$SEEN" == *B* ]]; then ok "both backends in rotation"
else warn "only one backend answers - the other is DOWN or marked failed (the service still works thanks to failover)"; fi

if [ "${DEEP:-0}" = 1 ]; then
    hdr DEEP "Edge -> backend hop (run on the edge that serves $HOST)"
    EN=mac2; [ "$TARGET" = "$EDGE2_IP" ] && EN=mac3
    run_on "$EN" "for b in $BACKEND_A $BACKEND_B; do printf '  %s -> ' \$b; curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://\$b/api/status || echo unreachable; done; echo '  nginx upstreams:'; grep -E '^\s*server .*:[0-9]+' ~/cn-project/nginx/cn-project.conf | sed 's/^/    /'; echo '  last errors:'; tail -2 ~/cn-project/logs/nginx-error.log | cut -c1-200 | sed 's/^/    /'"
fi
echo; echo "${G}${B}>>> All layers healthy.${N}"
