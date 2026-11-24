#!/bin/bash
# run-tests.sh - automated Phase 1 regression + Phase 2 extension tests.
# Run on Satyam's Mac (Mac 1): it is the test client and drives the other
# Macs over SSH. Every run is saved to evidence/phase_2/logs/<test>.log, so
# the output itself is the evidence (commands + real results + PASS/FAIL).
#
#   scripts/phase2/run-tests.sh p1        Phase 1 regression (Tasks A-F)
#   scripts/phase2/run-tests.sh p1fail    Phase 1 failure demonstrations (brief section 6.3)
#   scripts/phase2/run-tests.sh extA      backup DNS failover
#   scripts/phase2/run-tests.sh extB      TTL + controlled record change (flush needs sudo on this Mac)
#   scripts/phase2/run-tests.sh extC      service isolation (asks Akshit's sudo password for pf)
#   scripts/phase2/run-tests.sh extD      HA failover of Backend A
#   scripts/phase2/run-tests.sh extE      DNS-based edge cutover
#   scripts/phase2/run-tests.sh all       p1 p1fail extA extB extD extE  (extC separately: needs a password)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"
B=; C=; G=; Y=; R=; M=; N=          # plain text: these logs are evidence files
LOGDIR="$ROOT/evidence/phase_2/logs"; mkdir -p "$LOGDIR"
D="$TEAM_DOMAIN"

hr()   { printf '\n==== %s ====\n' "$*"; }
step() { printf '\n--- [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
show() { printf '$ %s\n' "$*"; eval "$*" 2>&1; }
on()   { local n="$1"; shift; printf '%s(%s)$ %s\n' "$n" "$(node_name "$n")" "$*"; run_on "$n" "$*" 2>&1; }
# Client mode: curl normally uses this Mac's system resolver (team DNS). If this Mac
# is not set up as a client yet, ask the team DNS explicitly and pin curl to that
# answer (still name-based + certificate-verified) - and say so in the log.
SYSOK=1; [ -n "$(sysresolve "$APP")" ] || SYSOK=0
curlx() {
    if [ $SYSOK = 1 ]; then curl "$@"; return; fi
    local ip; ip="$(dig @"$DNS1_IP" "$APP" +short +time=2 +tries=1 | tail -1)"
    [ -n "$ip" ] || ip="$(dig @"$DNS2_IP" "$APP" +short +time=2 +tries=1 | tail -1)"
    curl --cacert "$CA" --resolve "$APP:443:$ip" --resolve "$APP:80:$ip" --resolve "$APP:8443:$ip" "$@"
}
hit() { curlx -s -o /dev/null --max-time 6 -D - "https://$APP/api/status" 2>&1 | tr -d '\r' \
        | awk 'NR==1{c=$2} tolower($1)=="x-backend:"{b=$2} tolower($1)=="x-edge:"{e=$2} END{printf "%s backend=%s edge=%s\n", (c?c:"000"), b, e}'; }
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
both_record() { on mac1 "$CN dns-record $1"; on mac2 "$CN dns-record $1"; }

# ------------------------------------------------------------------ Phase 1
t_p1() {
    hr "PHASE 1 REGRESSION  $(date)"
    step "Task A - inventory of each Mac (interface, IPv4, mask, gateway, MAC address)"
    for n in "${NODES[@]}"; do
        on "$n" 'echo "host=$(hostname -s) if=en0 ip=$(ipconfig getifaddr en0) mask=$(ipconfig getoption en0 subnet_mask) gw=$(ipconfig getoption en0 router) mac=$(ifconfig en0 | awk "/ether/{print \$2}")"'
    done
    step "Task A - ping matrix (every pair)"
    on mac1 "for h in $MAC2_IP $MAC3_IP; do ping -c 2 -q \$h | tail -1 | sed \"s#^#\$h #\"; done"
    on mac2 "for h in $MAC1_IP $MAC3_IP; do ping -c 2 -q \$h | tail -1 | sed \"s#^#\$h #\"; done"
    on mac3 "for h in $MAC1_IP $MAC2_IP; do ping -c 2 -q \$h | tail -1 | sed \"s#^#\$h #\"; done"
    check "Mac 1 reaches Mac 2 and Mac 3" "ping -c1 -t2 $MAC2_IP >/dev/null && ping -c1 -t2 $MAC3_IP >/dev/null"
    step "Task B - both resolvers answer the project names (TTL $DNS_TTL)"
    for s in "$DNS1_IP" "$DNS2_IP"; do show "dig +nocmd @$s $APP +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"; show "dig @$s $API +short"; done
    check "primary DNS answers $APP -> $APP_RECORD_IP" "[ \"\$(dig @$DNS1_IP $APP +short)\" = $APP_RECORD_IP ]"
    check "backup DNS answers $APP -> $APP_RECORD_IP"  "[ \"\$(dig @$DNS2_IP $APP +short)\" = $APP_RECORD_IP ]"
    show "dig +nocmd @$DNS1_IP nosuchhost.$D +noall +comments | grep status   # authoritative for $D: NXDOMAIN"
    show "dig +nocmd @8.8.8.8 $APP +noall +comments | grep status             # the public Internet has never heard of it"
    step "Task B - this client's system resolver"
    show "networksetup -getdnsservers Wi-Fi | xargs"
    show "dig +nocmd $APP +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"
    show "dscacheutil -q host -a name $APP | grep ip_address"
    step "Task C - backends reachable on the LAN from the edge (Mac 2), X-Backend header"
    on mac2 "curl -s -i http://$BACKEND_A/api/status | grep -iE '^HTTP|^X-Backend|backend'"
    on mac2 "curl -s -i http://$BACKEND_B/api/status | grep -iE '^HTTP|^X-Backend|backend'"
    on mac3 "lsof -nP -iTCP:3001 -iTCP:3002 -sTCP:LISTEN | awk 'NR>1{print \$1, \$9}'"
    step "Task D+E - HTTPS by name, certificate verified (no -k), HTTP/2 and HTTP/1.1"
    show "curlx -sv https://$APP/api/status -o /dev/null 2>&1 | grep -E 'Connected to|SSL connection|ALPN|subject:|issuer:|SSL certificate verify|^< HTTP|^< x-'"
    show "curlx -s --http1.1 -I https://$APP/api/status | head -1"
    check "TLS verifies without -k" "curlx -s -o /dev/null https://$APP/api/status"
    step "Task D - round robin (8 requests)"
    local seen="" i r
    for i in 1 2 3 4 5 6 7 8; do r="$(hit)"; printf '  #%s %s\n' "$i" "$r"; seen+="$r "; done
    check "both backends served requests" "[[ \"$seen\" == *backend=A* && \"$seen\" == *backend=B* ]]"
    step "Task F - caching: Cache-Control + ETag, then a conditional request -> 304"
    show "curlx -sI https://$APP/api/cache | grep -iE '^HTTP|cache-control|etag|x-backend'"
    show "curlx -si -H 'If-None-Match: \"cn-cache-v1\"' https://$APP/api/cache | grep -iE '^HTTP|etag|content-length'"
    check "conditional GET returns 304" "[ \"\$(curlx -s -o /dev/null -w '%{http_code}' -H 'If-None-Match: \"cn-cache-v1\"' https://$APP/api/cache)\" = 304 ]"
    show "curlx -sI https://$APP/api/status | grep -i cache-control   # the dynamic endpoint is never cached"
    step "Phase 2 hardening - port 80 redirects to HTTPS"
    show "curlx -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://$APP/api/status"
}

# ------------------------------------------------------------------ Phase 1 failures (6.3)
t_p1fail() {
    hr "PHASE 1 FAILURE DEMONSTRATIONS (brief 6.3)  $(date)"
    step "F1 Wrong DNS server: ask resolvers that do not know our zone"
    show "dig +nocmd @8.8.8.8 $APP +noall +comments | grep status"
    show "dig @$MAC3_IP $APP +time=2 +tries=1 | grep -E 'status|timed out|refused|no servers'   # no DNS server on Mac 3"
    show "nc -z -G 3 $EDGE1_IP 443 && echo 'but TCP to the edge IP still works -> DNS and IP are independent layers'"
    step "F2 Record points to a wrong IP (resolution OK, connection goes to the wrong place)"
    show "curl -s --max-time 4 --cacert $CA --resolve $APP:443:$MAC1_IP https://$APP/api/status; echo \"exit=\$? (7 = refused: Mac 1 has no web server)\""
    step "F3 One backend stopped -> service continues"
    on mac3 "$CN backend stop A"
    local i; for i in 1 2 3 4; do printf '  #%s ' "$i"; hit; done
    on mac3 "$CN backend start A"
    step "F4 Both backends stopped -> DNS + TCP + TLS fine, edge answers 502"
    on mac3 "$CN backend stop"
    show "dig @$DNS1_IP $APP +short"
    show "curlx -sv https://$APP/api/status 2>&1 | grep -E 'SSL certificate verify|^< HTTP|^< x-edge'"
    check "both backends down -> 502 Bad Gateway" "[ \"\$(curlx -s -o /dev/null -w '%{http_code}' https://$APP/api/status)\" = 502 ]"
    on mac2 "tail -2 ~/cn-project/logs/nginx-error.log | cut -c1-200"
    on mac3 "$CN backend start"
    step "F5 Wrong destination port: host reachable, port closed"
    show "curlx -s --max-time 4 https://$APP:8443/api/status; echo \"exit=\$? (7 = connection refused on :8443)\""
    show "nc -z -G 3 $EDGE1_IP 443 && echo ':443 on the same host is open'"
    sleep 11   # let nginx re-admit the backends before the next test
}

# ------------------------------------------------------------------ Ext A
t_extA() {
    hr "EXTENSION A - BACKUP DNS RESOLVER  $(date)"
    step "Client resolver list (both servers) and both resolvers up"
    show "networksetup -getdnsservers Wi-Fi | xargs"
    show "scutil --dns | awk '/resolver #1/,/^\$/' | grep nameserver"
    on mac1 "$CN dns status"; on mac2 "$CN dns status"
    show "dig +nocmd $APP +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"
    step "Stop the PRIMARY (dnsmasq on Mac 1)"
    on mac1 "$CN dns stop"
    show "dig @$DNS1_IP $APP +time=2 +tries=1 | grep -E 'refused|timed out|status|no servers'"
    step "The backup resolver has the same records"
    show "dig +nocmd @$DNS2_IP $APP +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"
    step "System resolver (curl/browsers): wait for the cached entry to expire, then resolve again"
    sleep $((DNS_TTL + 2))
    show "dig +nocmd $APP +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"
    show "dscacheutil -q host -a name $APP | grep ip_address"
    printf '  HTTPS while the primary is down: '; hit
    check "client still resolves with the primary down" "[ -n \"\$(sysresolve $APP)\" ]"
    check "HTTPS still 200 with the primary down" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://$APP/api/status)\" = 200 ]"
    on mac2 "grep -i 'query\\[A\\] $APP' ~/cn-project/logs/dnsmasq.log | tail -3   # the BACKUP served the client"
    step "DNS failure vs application failure"
    show "dig @$DNS2_IP $APP +short   # name resolution works ..."
    on mac3 "$CN backend stop"
    show "curl -s -o /dev/null -w 'HTTP %{http_code}\n' https://$APP/api/status   # ... but the application is down (502)"
    on mac3 "$CN backend start"
    step "Restore the primary"
    on mac1 "$CN dns start"
    show "dig +nocmd $APP +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"
    sleep 11
}

# ------------------------------------------------------------------ Ext B
t_extB() {
    hr "EXTENSION B - TTL AND CONTROLLED RECORD CHANGE  $(date)"
    local OLD="$APP_RECORD_IP" NEW="$EDGE2_IP"
    step "Record TTL is $DNS_TTL s (2nd column of the answer)"
    show "dig +nocmd @$DNS1_IP $APP +noall +answer"
    step "Client resolves -> the answer is now cached by this client (mDNSResponder)"
    show "dscacheutil -q host -a name $APP | grep ip_address"
    local t0; t0=$(date +%s)
    step "Change the record to $NEW (Akshit's standby edge) on BOTH resolvers"
    both_record "$NEW"
    show "dig +nocmd @$DNS1_IP $APP +noall +answer   # the authoritative answer changes immediately"
    step "Poll this client every 5 s: cached (old) answer until the TTL expires"
    local flipped=0 ans
    for _ in $(seq 1 10); do
        ans="$(sysresolve "$APP")"; printf '  t=+%02ds client=%-13s server=%s\n' $(( $(date +%s) - t0 )) "$ans" "$(dig @"$DNS1_IP" "$APP" +short)"
        [ "$ans" = "$NEW" ] && { flipped=1; break; }
        sleep 5
    done
    check "client switched to the new IP within TTL + slack" "[ $flipped = 1 ]"
    step "Change it back, then flush the client cache manually -> immediate change"
    show "dscacheutil -q host -a name $APP | grep ip_address   # (re)cache NEW"
    both_record "$OLD"
    show "dscacheutil -q host -a name $APP | grep ip_address   # still NEW: cached"
    if sudo -n true 2>/dev/null; then
        show "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
        show "dscacheutil -q host -a name $APP | grep ip_address   # OLD immediately after the flush"
        check "flush gives the new answer at once" "[ \"\$(sysresolve $APP)\" = $OLD ]"
    else
        echo "  (no cached sudo: run 'sudo -v' first to show the manual flush; waiting out the TTL instead)"
        local k; for k in $(seq 0 11); do a="$(sysresolve "$APP")"; printf '  +%02ds client=%s\n' $((k*5)) "$a"; [ "$a" = "$OLD" ] && break; sleep 5; done
    fi
}

# ------------------------------------------------------------------ Ext C
t_extC() {
    hr "EXTENSION C - SERVICE ISOLATION (pf on Akshit's Mac)  $(date)"
    step "BEFORE: a client (Mac 1) can reach the backends directly"
    show "curl -s -m 4 -o /dev/null -w 'client -> A: %{http_code}\n' http://$BACKEND_A/api/status"
    step "Apply the firewall on Mac 3 (sudo - Akshit's password)"
    show "grep -vE '^[[:space:]]*(#|\$)' $ROOT/config/rendered/mac3/pf-backend-isolation.conf"
    run_on_tty mac3 "sudo ~/cn-project/bin/firewall.sh apply" 2>&1
    step "Edge (Mac 2) -> backends: allowed"
    on mac2 "curl -s -m 4 -o /dev/null -w 'edge -> A: %{http_code}\n' http://$BACKEND_A/api/status; curl -s -m 4 -o /dev/null -w 'edge -> B: %{http_code}\n' http://$BACKEND_B/api/status"
    step "Client (Mac 1) -> backends directly: blocked (SYN dropped -> timeout, exit 28)"
    show "curl -s -m 4 -o /dev/null http://$BACKEND_A/api/status; echo \"client -> A exit=\$?\""
    show "nc -z -G 3 ${BACKEND_B%:*} ${BACKEND_B#*:}; echo \"client -> B nc exit=\$?\""
    check "edge reaches backend A" "[ \"\$(run_on mac2 \"curl -s -m 4 -o /dev/null -w '%{http_code}' http://$BACKEND_A/api/status\")\" = 200 ]"
    check "client blocked from backend A" "! curl -s -m 4 -o /dev/null http://$BACKEND_A/api/status"
    check "client blocked from backend B" "! nc -z -G 3 ${BACKEND_B%:*} ${BACKEND_B#*:} 2>/dev/null"
    step "Packet capture while the firewall is on (client side: SYNs retransmitted, never answered)"
    "$ROOT/scripts/phase2/capture.sh" isolation 2>&1 | head -14
    step "Client through the edge: still works"
    printf '  '; hit
    check "service via the edge still 200" "[ \"\$(curlx -s -o /dev/null -w '%{http_code}' https://$APP/api/status)\" = 200 ]"
    step "Rollback (restore the original firewall state)"
    run_on_tty mac3 "sudo ~/cn-project/bin/firewall.sh rollback" 2>&1
    check "client reaches backend A again after rollback" "curl -s -m 4 -o /dev/null http://$BACKEND_A/api/status"
}

# ------------------------------------------------------------------ Ext D
t_extD() {
    hr "EXTENSION D - HIGH-AVAILABILITY FAILOVER  $(date)"
    step "Both healthy: round robin"
    local i r codes=""; for i in 1 2 3 4; do printf '  #%s ' "$i"; hit; done
    step "Stop Backend A"
    on mac3 "$CN backend stop A"
    for i in 1 2 3 4 5 6 7 8; do r="$(hit)"; printf '  #%s %s\n' "$i" "$r"; codes+="${r%% *} "; done
    check "all 8 requests succeeded (served by B)" "[ \"\$(echo $codes | tr ' ' '\n' | sort -u | xargs)\" = 200 ]"
    on mac2 "grep -E 'upstream_status=50[0-9], ' ~/cn-project/logs/nginx-access.log | tail -2"
    on mac2 "grep -E 'refused|temporarily disabled' ~/cn-project/logs/nginx-error.log | tail -2 | cut -c1-200"
    step "Restart Backend A - after fail_timeout (10 s) nginx retries it and it rejoins"
    on mac3 "$CN backend start A"
    sleep 11
    local seen=""; for i in 1 2 3 4 5 6; do r="$(hit)"; printf '  #%s %s\n' "$i" "$r"; seen+="$r "; done
    check "A is back in rotation" "[[ \"$seen\" == *backend=A* && \"$seen\" == *backend=B* ]]"
    on mac2 "tail -6 ~/cn-project/logs/nginx-access.log | grep -oE 'upstream=[^ ]+ upstream_status=[^ ]+'"
}

# ------------------------------------------------------------------ Ext E
t_extE() {
    hr "EXTENSION E - DNS-BASED EDGE CUTOVER  $(date)"
    step "Standby edge (Mac 3) runs the same config + certificate; prove it serves before the cutover"
    show "curlx -s --resolve $APP:443:$EDGE2_IP -D - https://$APP/edge-health | grep -iE 'x-edge|edge2'"
    step "Client A (this Mac) primes its cache: it must be on edge1 before we start"
    local w=0 r0
    while :; do r0="$(hit)"; [[ "$r0" == *edge1* ]] && break; w=$((w+1)); [ $w -gt 20 ] && { echo "  client never reached edge1 - aborting"; return 1; }; sleep 4; done
    printf '  %s\n' "$r0"
    local t0; t0=$(date +%s)
    step "CUTOVER: $APP -> $EDGE2_IP on both resolvers"
    both_record "$EDGE2_IP"
    step "Client B (Mac 3) - a NEW lookup - goes to the standby immediately"
    on mac3 "ip=\$(dig @$DNS1_IP $APP +short); echo \"fresh lookup: $APP -> \$ip\"; curl -s --cacert ~/cn-project/tls/mkcert-rootCA.pem --resolve $APP:443:\$ip -D - -o /dev/null https://$APP/api/status | grep -iE 'x-edge|x-backend'"
    step "Client A (this Mac, cached answer) keeps hitting the OLD edge until the TTL expires"
    local moved=0 r
    for _ in $(seq 1 20); do
        r="$(hit)"; printf '  t=+%02ds %s\n' $(( $(date +%s) - t0 )) "$r"
        [[ "$r" == *edge2* ]] && { moved=1; break; }
        sleep 4
    done
    check "client A moved to edge2 after the TTL" "[ $moved = 1 ]"
    step "The old edge can now be stopped for maintenance - nobody notices"
    on mac2 "$CN edge stop"
    printf '  '; hit
    check "service up with edge1 stopped" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://$APP/api/status)\" = 200 ]"
    step "Roll back: edge1 up, record back to $EDGE1_IP"
    on mac2 "$CN edge start"
    both_record "$EDGE1_IP"
}

run() {
    local t="$1" log="$LOGDIR/$1.log"
    {
        echo "# run-tests.sh $t - client $(hostname -s) ($(ipconfig getifaddr en0)) - $(date)"
        [ $SYSOK = 1 ] || echo "NOTE: this client's DNS is not set to the team resolvers - curl is pinned to the team DNS answer."
        "t_$t"
        echo; echo "RESULT ($t): $PASS passed, $FAIL failed"
    } 2>&1 | tee "$log"
    echo "log: ${log#$ROOT/}"
}
case "${1:-}" in
    p1|p1fail|extA|extB|extC|extD|extE) run "$1" ;;
    all) for t in p1 p1fail extA extB extD extE; do PASS=0; FAIL=0; run "$t"; done ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
esac
