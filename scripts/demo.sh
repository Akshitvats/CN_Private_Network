#!/bin/bash
# demo.sh - guided, plain-English presenter for the final demo (Phase 1 + Phase 2).
# Run on Satyam's Mac (Mac 1) from the project folder. It drives the other Macs over SSH.
#
#   scripts/demo.sh who      who is who (names, IPs, roles) + live status of every Mac
#   scripts/demo.sh check    is everything healthy?
#   scripts/demo.sh p1       Phase 1 recap = final-demo steps 2-8 (ping, dig, HTTPS, LB, caching, failover)
#   scripts/demo.sh A        Ext A  backup DNS resolver
#   scripts/demo.sh B        Ext B  DNS TTL + controlled record change    [asks Satyam's password: cache flush]
#   scripts/demo.sh C        Ext C  firewall around the backends           [asks Akshit's password: pf]
#   scripts/demo.sh D        Ext D  a backend dies, the service survives
#   scripts/demo.sh E        Ext E  DNS cutover to the standby edge
#   scripts/demo.sh F        Ext F  find a fault layer by layer (diagnose.sh)
#   scripts/demo.sh break [fault]   practice: inject a (random) hidden fault
#   scripts/demo.sh answer          reveal which fault was injected
#   scripts/demo.sh fix             put EVERYTHING back to normal (use whenever something looks wrong)
#
# NOPAUSE=1 scripts/demo.sh A    runs without waiting for Enter.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"
STATE="$ROOT/config/.demo-fault"

title() { echo; echo "${B}${M}════════════════════════════════════════════════════════════════${N}"; echo "${B}${M}  $*${N}"; echo "${B}${M}════════════════════════════════════════════════════════════════${N}"; }
idea()  { echo "${B}IDEA:${N} $*"; }
step()  { echo; echo "${B}${C}▶ $*${N}"; }
say()   { echo "${G}🗣  SAY:${N} $*"; }
look()  { echo "${Y}👀 LOOK AT:${N} $*"; }
pause() { [ "${NOPAUSE:-0}" = 1 ] && return; printf "\n   ${B}[press Enter to continue]${N}"; read -r _; }
run()   { echo "   ${B}\$ $*${N}"; eval "$*" 2>&1 | sed 's/^/     /'; }                       # on this Mac
on()    { local n="$1"; shift; echo "   ${B}[on $(node_name "$n")'s Mac]\$ $*${N}"; run_on "$n" "$*" 2>&1 | sed 's/^/     /'; }
# One HTTPS request via the system resolver, verified cert: "200  backend=A  edge=edge1-mac2"
hit()   { curl -s -o /dev/null --max-time 6 -D - "https://$APP/api/status" 2>/dev/null | tr -d '\r' \
          | awk 'NR==1{c=$2} tolower($1)=="x-backend:"{b=$2} tolower($1)=="x-edge:"{e=$2} END{printf "%s  backend=%s  edge=%s\n", (c?c:"FAILED"), b, e}'; }
hits()  { local i; for i in $(seq 1 "${1:-6}"); do printf '     request %s: ' "$i"; hit; done; }
both_dns_record() { run_on mac1 "$CN dns-record $1" >/dev/null; run_on mac2 "$CN dns-record $1" >/dev/null; }
# Wait until this Mac's cached answer points at the normal edge again.
wait_normal() { local i=0; while [ "$(sysresolve "$APP")" != "$APP_RECORD_IP" ] && [ $i -lt 12 ]; do
                  [ $i = 0 ] && echo "     (this Mac still remembers an old DNS answer - waiting for its ${DNS_TTL}s TTL...)"; sleep 4; i=$((i+1)); done; }
need_client() {
    [ -n "$(sysresolve "$APP")" ] && return 0
    echo "${R}This Mac cannot resolve $APP through its system resolver.${N} Run once:  sudo scripts/phase2/client-setup.sh"; exit 1
}

# ------------------------------------------------------------------ who / check
who() {
  title "WHO IS WHO  (remember the NAMES - the IPs are just today's addresses)"
  cat <<EOF

  ${B}Satyam's Mac${N}   $MAC1_IP   ${B}DNS #1${N} (primary phone book: app.teamX.test -> address) + test client
  ${B}Krishna's Mac${N}  $MAC2_IP   ${B}FRONT DOOR${N} (nginx edge1: HTTPS + load balancer) + ${B}DNS #2${N} (backup phone book)
  ${B}Akshit's Mac${N}   $MAC3_IP   ${B}BACKEND A${N} (:3001) + ${B}BACKEND B${N} (:3002)
                                 + ${B}SPARE FRONT DOOR${N} (nginx edge2, Ext E) + ${B}FIREWALL${N} (pf, Ext C)

  app.teamX.test / api.teamX.test  ->  ${B}$APP_RECORD_IP${N} (Krishna's front door), TTL ${DNS_TTL}s

  One request:
    client --"where is app.teamX.test?" (UDP 53)--> Satyam (DNS #1)   [Krishna = DNS #2 if #1 is down]
    client <--"at $APP_RECORD_IP, remember 30 s"--
    client --TCP 443 + TLS (HTTPS, HTTP/2)--> Krishna (nginx) --HTTP/1.1 round robin--> Akshit :3001 / :3002
EOF
  step "Live status of every Mac"
  for n in "${NODES[@]}"; do on "$n" "$CN status | tail -n +2"; done
}

check() {
  title "HEALTH CHECK - is everything working?"
  need_client
  wait_normal
  step "1) Can this Mac find app.teamX.test?  (DNS)"
  run "dig +nocmd $APP +noall +answer +stats | grep -E 'IN|SERVER'"
  step "2) Does the website work over HTTPS, with load balancing?"
  hits 4
  step "3) Layer-by-layer check"
  "$ROOT/scripts/diagnose.sh" 2>&1 | grep -E '>>>|likely|next step' | sed 's/^/     /'
  say "200, backends A and B taking turns, and 'All layers healthy' = ready."
}

# ------------------------------------------------------------------ Phase 1 recap (final demo steps 2-8)
p1() {
  title "PHASE 1 RECAP  (final demonstration steps 2 - 8)"
  need_client
  wait_normal
  step "Step 2 - all Macs on the same LAN (ping) + this Mac's address"
  run "ipconfig getifaddr en0"
  run "ping -c 2 -q $MAC2_IP | tail -1; ping -c 2 -q $MAC3_IP | tail -1"
  pause
  step "Step 3 - resolve the private name with OUR DNS server"
  run "dig +nocmd $APP +noall +answer +stats | grep -E 'IN|SERVER'"
  run "dig +nocmd @8.8.8.8 $APP +noall +comments | grep status    # the public Internet has never heard of it"
  look "answer = $APP_RECORD_IP (Krishna's front door), SERVER = $DNS1_IP (Satyam's DNS)."
  pause
  step "Step 4 - HTTPS by NAME, certificate verified (no -k), no IP in the URL"
  run "curl -sv https://$APP/api/status -o /dev/null 2>&1 | grep -E 'Connected to|SSL connection|ALPN|subject:|issuer:|SSL certificate verify|^< HTTP'"
  run "curl -s --http1.1 -I https://$APP/api/status | head -1;  curl -s --http2 -I https://$APP/api/status | head -1"
  say "TLS is terminated at nginx. The cert is for app.teamX.test, signed by our team CA, which every client trusts."
  pause
  step "Step 5 - load balancing: X-Backend alternates A / B"
  hits 6
  pause
  step "Step 6 - Wireshark evidence: open the saved captures"
  run "ls evidence/phase_1/*.pcapng evidence/phase_2/captures/*.pcapng 2>/dev/null"
  say "Filters: dns  |  tcp.flags.syn==1 && tcp.port==443  |  tls.handshake  - DNS, then TCP 3-way handshake, then TLS."
  pause
  step "Step 7 - HTTP caching: Cache-Control + ETag, then a conditional request -> 304"
  run "curl -sI https://$APP/api/cache | grep -iE '^HTTP|cache-control|etag'"
  run "curl -si -H 'If-None-Match: \"cn-cache-v1\"' https://$APP/api/cache | grep -iE '^HTTP|etag|content-length'"
  say "max-age=60 = fresh cache hit for 60 s (no request at all); after that the client revalidates with If-None-Match and gets 304 with no body."
  pause
  step "Step 8 - stop Backend A (Akshit's Mac): the service continues through B"
  on mac3 "$CN backend stop A"
  hits 4
  on mac3 "$CN backend start A"
  say "That is Extension D in detail - next: demo.sh D."
}

# ------------------------------------------------------------------ Extension A
ext_A() {
  title "EXTENSION A - BACKUP DNS RESOLVER  (spare phone book)"
  need_client
  wait_normal
  idea "Clients know TWO DNS servers: Satyam's (#1) and Krishna's (#2). If #1 dies, they ask #2."
  step "Both resolvers hold the same records"
  run "dig @$DNS1_IP $APP +short    # Satyam (primary)"
  run "dig @$DNS2_IP $APP +short    # Krishna (backup)"
  run "networksetup -getdnsservers Wi-Fi | xargs    # this client lists BOTH"
  pause
  step "BREAK IT: stop DNS #1 (dnsmasq on Satyam's Mac)"
  on mac1 "$CN dns stop"
  run "dig @$DNS1_IP $APP +time=2 +tries=1 | grep -E 'timed out|refused|status|no servers'"
  look "the primary does not answer any more."
  pause
  step "The website STILL works: the client falls back to DNS #2 (Krishna)"
  echo "     (waiting $((DNS_TTL + 3)) s so this Mac's cached answer expires and it really has to ask again...)"; sleep $((DNS_TTL + 3))
  run "dig +nocmd $APP +noall +answer +stats | grep -E 'IN|SERVER'"
  run "dscacheutil -q host -a name $APP | grep ip_address    # system resolver (curl/browser)"
  hits 2
  on mac2 "grep -i 'query\\[A\\] $APP' ~/cn-project/logs/dnsmasq.log | tail -2"
  look "SERVER is now $DNS2_IP (Krishna), Krishna's dnsmasq log shows our query, and requests still return 200."
  pause
  step "DNS failure vs application failure"
  say "DNS failure: the NAME cannot be found, so nothing even starts (no IP -> no TCP -> no TLS)."
  say "Application failure: the name resolves and TCP/TLS work, but the app is down -> the edge answers 502."
  step "FIX IT: start DNS #1 again"
  on mac1 "$CN dns start"
  run "dig +nocmd $APP +noall +answer +stats | grep -E 'IN|SERVER'"
}

# ------------------------------------------------------------------ Extension B
ext_B() {
  title "EXTENSION B - DNS TTL AND A CONTROLLED RECORD CHANGE"
  need_client
  idea "Every answer says 'remember me for ${DNS_TTL} s' (TTL). Change the record and clients keep the OLD answer until their timer runs out."
  echo "   (the manual cache flush at the end needs Satyam's Mac password)"; sudo -v || return 1
  step "The record and its TTL (2nd column)"
  run "dig +nocmd @$DNS1_IP $APP +noall +answer"
  run "dscacheutil -q host -a name $APP | grep ip_address    # this Mac now has it CACHED"
  pause
  step "CHANGE the record -> $EDGE2_IP (Akshit's Mac) on BOTH resolvers"
  on mac1 "$CN dns-record $EDGE2_IP"; on mac2 "$CN dns-record $EDGE2_IP"
  run "dig @$DNS1_IP $APP +short    # the SERVER changed immediately"
  pause
  step "But this Mac keeps the OLD answer until its TTL expires (checking every 5 s)"
  local t0 ans; t0=$(date +%s)
  for _ in $(seq 1 12); do
    ans="$(sysresolve "$APP")"
    printf '     after %2ss   this Mac uses: %-13s   DNS server says: %s\n' $(( $(date +%s)-t0 )) "$ans" "$(dig @"$DNS1_IP" "$APP" +short)"
    [ "$ans" = "$EDGE2_IP" ] && break; sleep 5
  done
  look "the left column stays OLD for up to ${DNS_TTL} s, then flips to the NEW IP."
  say "That is why you LOWER the TTL before migrating a service: a change reaches everyone only after one TTL."
  pause
  step "Change it BACK, then FLUSH this Mac's cache by hand -> the change is instant"
  on mac1 "$CN dns-record $APP_RECORD_IP"; on mac2 "$CN dns-record $APP_RECORD_IP"
  run "dscacheutil -q host -a name $APP | grep ip_address    # still the cached one"
  run "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder    # forget all cached answers"
  run "dscacheutil -q host -a name $APP | grep ip_address    # back to $APP_RECORD_IP immediately"
  say "A flush makes the client ask the server again at once. In production you cannot flush every user's cache - so you wait one TTL."
}

# ------------------------------------------------------------------ Extension C
ext_C() {
  title "EXTENSION C - SERVICE ISOLATION  (firewall in front of the backends)"
  idea "Only Krishna's front door may talk to the backends on Akshit's Mac. Everyone else must go through HTTPS on the edge."
  step "BEFORE: no firewall - Satyam's Mac can reach Backend A directly (bypassing the edge)"
  run "curl -s -m 4 http://$BACKEND_A/api/status; echo \"  exit=\$?\""
  say "Without isolation anyone on the Wi-Fi could skip TLS and the load balancer."
  pause
  step "Turn the firewall ON (pf on Akshit's Mac - type AKSHIT's password)"
  echo "   ${B}[on Akshit's Mac]\$ sudo ~/cn-project/bin/firewall.sh apply${N}"
  run_on_tty mac3 "sudo ~/cn-project/bin/firewall.sh apply" 2>&1 | sed 's/^/     /'
  look "'pass ... from $EDGE1_IP' = Krishna allowed;  'block drop' = everyone else silently dropped."
  pause
  step "AFTER: Satyam (a client) is blocked - expect a 4 s wait, then exit=28 (timeout)"
  run "curl -s -m 4 http://$BACKEND_A/api/status; echo \"  exit=\$?\""
  run "nc -z -G 3 ${BACKEND_B%:*} ${BACKEND_B#*:}; echo \"  nc exit=\$?   (port 3002 too)\""
  step "Krishna's front door is still allowed in (expect 200)"
  on mac2 "curl -s -m 4 -o /dev/null -w 'edge -> A: %{http_code}\n' http://$BACKEND_A/api/status; curl -s -m 4 -o /dev/null -w 'edge -> B: %{http_code}\n' http://$BACKEND_B/api/status"
  step "Users going through the front door still get the website"
  hits 2
  say "exit 28 = TIMEOUT: pf drops the SYN silently. A stopped server answers RST -> 'connection refused' instantly (exit 7). That is how you tell a firewall from a dead service."
  pause
  step "Turn the firewall OFF again (rollback, as the brief requires)"
  run_on_tty mac3 "sudo ~/cn-project/bin/firewall.sh rollback" 2>&1 | sed 's/^/     /'
  run "curl -s -m 4 -o /dev/null -w 'direct to A after rollback: %{http_code}\n' http://$BACKEND_A/api/status"
}

# ------------------------------------------------------------------ Extension D
ext_D() {
  title "EXTENSION D - HIGH AVAILABILITY: A BACKEND DIES, THE SERVICE SURVIVES"
  need_client
  wait_normal
  idea "nginx notices a dead backend (connection refused), retries the request on the healthy one and stops sending traffic to the dead one for 10 s."
  step "Normal: A and B take turns (round robin)"
  hits 4
  pause
  step "BREAK IT: stop Backend A on Akshit's Mac"
  on mac3 "$CN backend stop A"
  hits 6
  look "all 200, all backend=B - users see no errors."
  on mac2 "grep -E 'refused|upstream server temporarily disabled' ~/cn-project/logs/nginx-error.log | tail -2 | cut -c1-170"
  on mac2 "grep 'upstream_status=50' ~/cn-project/logs/nginx-access.log | tail -1"
  say "upstream_status=502, 200 = nginx tried A, it failed, and the SAME request was retried on B."
  pause
  step "FIX IT: start Backend A; after fail_timeout (10 s) nginx tries it again"
  on mac3 "$CN backend start A"
  echo "     (waiting 11 s...)"; sleep 11
  hits 4
  look "A and B take turns again."
  say "Remaining single point of failure: the edge itself (one nginx on Krishna's Mac). Fix: a second edge with a shared floating IP (VRRP/keepalived) or a cloud load balancer; our manual version is Extension E."
}

# ------------------------------------------------------------------ Extension E
ext_E() {
  title "EXTENSION E - CONTROLLED EDGE MIGRATION (DNS-based cutover)"
  need_client
  idea "Akshit's Mac runs a SECOND nginx with the same config + certificate. We move users there just by changing the DNS record."
  step "The standby edge is ready (asked directly, bypassing DNS)"
  run "curl -s --resolve $APP:443:$EDGE2_IP https://$APP/edge-health"
  step "Right now this Mac uses the MAIN edge (edge=edge1-mac2) and has that answer cached"
  local w=0; until hit | grep -q edge1; do w=$((w+1)); [ $w -gt 15 ] && break; sleep 4; done
  hits 1
  pause
  step "CUTOVER: app.teamX.test -> $EDGE2_IP (Akshit) on both resolvers"
  on mac1 "$CN dns-record $EDGE2_IP"; on mac2 "$CN dns-record $EDGE2_IP"
  step "A NEW lookup goes to the standby IMMEDIATELY (Akshit's Mac as a fresh client)"
  on mac3 "ip=\$(dig @$DNS1_IP $APP +short); echo \"fresh lookup -> \$ip\"; curl -s --cacert ~/cn-project/tls/mkcert-rootCA.pem --resolve $APP:443:\$ip -D - -o /dev/null https://$APP/api/status | grep -i x-edge"
  step "This Mac had the OLD answer cached -> keeps using the OLD edge until its TTL runs out"
  local t0 r; t0=$(date +%s)
  for _ in $(seq 1 14); do r="$(hit)"; printf '     after %2ss: %s\n' $(( $(date +%s)-t0 )) "$r"; [[ "$r" == *edge2* ]] && break; sleep 4; done
  look "edge changes from edge1-mac2 to edge2-mac3 after about ${DNS_TTL} s."
  say "New lookups move at once, cached clients move when their TTL expires - so keep the old edge running for one TTL after a cutover."
  pause
  step "Now the old edge can be taken down for maintenance - nobody notices"
  on mac2 "$CN edge stop"
  hits 2
  pause
  step "Put it back: edge1 up, record -> Krishna's front door"
  on mac2 "$CN edge start"
  on mac1 "$CN dns-record $EDGE1_IP"; on mac2 "$CN dns-record $EDGE1_IP"
  wait_normal; hits 1
  say "The same certificate works on both edges because TLS checks the NAME (app.teamX.test), not the IP."
}

# ------------------------------------------------------------------ Extension F
ext_F() {
  title "EXTENSION F - FIND THE FAULT, LAYER BY LAYER"
  idea "Bottom-up: my network -> DNS -> can I reach the IP -> is the port open -> TLS -> HTTP -> backends. The FIRST failing layer is the problem."
  "$ROOT/scripts/diagnose.sh"
  cat <<EOF

  ${B}How to read it:${N}
    L2 DNS fails            -> resolver(s) down, wrong record, or the client uses the wrong DNS server
    L4 refused (instantly)  -> nothing listening: nginx stopped / wrong port / wrong IP in DNS
    L4 timeout (slow)       -> a firewall is silently dropping packets
    L5 TLS fails            -> wrong / expired / untrusted certificate, or name not in the SAN
    HTTP 502 (L7)           -> the edge is fine, the BACKENDS are not reachable from it
  Deeper:  DEEP=1 scripts/diagnose.sh   (tests the edge -> backend hop on the edge itself)
EOF
  say "We always check DNS first, then TCP, then TLS, then the application, and stop at the first layer that fails."
}

# ------------------------------------------------------------------ break / answer / fix (practice)
FAULTS=(dns1-down both-dns-down wrong-record edge-down edge-wrong-port backend-a-down both-backends-down wrong-upstream-port wrong-cert)
SITE='~/cn-project/nginx/cn-project.conf'
brk() {
  local f="${1:-${FAULTS[$((RANDOM % ${#FAULTS[@]}))]}}"
  wait_normal
  case "$f" in
    dns1-down)           run_on mac1 "$CN dns stop" ;;
    both-dns-down)       run_on mac1 "$CN dns stop"; run_on mac2 "$CN dns stop" ;;
    wrong-record)        both_dns_record "$MAC1_IP" ;;
    edge-down)           run_on mac2 "$CN edge stop" ;;
    edge-wrong-port)     run_on mac2 "sed -i '' 's/listen 443 ssl;/listen 8443 ssl;/' $SITE && $CN edge reload" ;;
    backend-a-down)      run_on mac3 "$CN backend stop A" ;;
    both-backends-down)  run_on mac3 "$CN backend stop" ;;
    wrong-upstream-port) run_on mac2 "sed -i '' -e 's/:3001 /:3011 /' -e 's/:3002 /:3012 /' $SITE && $CN edge reload" ;;
    wrong-cert)          run_on mac2 "cd ~/cn-project/tls && openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=wrong.test -keyout wrong.key -out wrong.crt 2>/dev/null && sed -i '' -e 's#tls/app.teamX.test.crt#tls/wrong.crt#' -e 's#tls/app.teamX.test.key#tls/wrong.key#' $SITE && $CN edge reload" ;;
    *) echo "unknown fault '$f'. Choose one of: ${FAULTS[*]}"; return 2 ;;
  esac >/dev/null 2>&1
  echo "$f" > "$STATE"
  title "A HIDDEN FAULT HAS BEEN INJECTED"
  echo "  Find it like in the exam:  ${B}scripts/demo.sh F${N}   (or scripts/diagnose.sh)"
  echo "  DNS faults show up only after this Mac's cached answer expires (${DNS_TTL} s) - or flush:"
  echo "      sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
  echo "  When you have a guess:     ${B}scripts/demo.sh answer${N}"
  echo "  To repair everything:      ${B}scripts/demo.sh fix${N}"
}
answer() {
  local f; f="$(cat "$STATE" 2>/dev/null || echo none)"
  echo "The injected fault was: ${B}$f${N}"
  case "$f" in
    dns1-down)           echo "Layer: DNS (primary only). The service still works through the backup resolver - that is Extension A." ;;
    both-dns-down)       echo "Layer: L2 DNS. No resolver answers -> the name cannot be resolved -> nothing else can start." ;;
    wrong-record)        echo "Layer: L2 DNS (wrong record). The name resolves, but to Satyam's Mac, which has no web server -> TCP refused." ;;
    edge-down)           echo "Layer: L4 TCP. DNS is fine but nothing listens on :443 at the edge -> connection refused." ;;
    edge-wrong-port)     echo "Layer: L4 TCP. nginx was moved to :8443, the client still dials :443 -> refused. Ports and IPs are separate identifiers." ;;
    backend-a-down)      echo "Layer: application. Hidden by failover (Ext D): everything returns 200 from B; diagnose shows only one backend in rotation." ;;
    both-backends-down)  echo "Layer: L7. DNS, TCP and TLS are fine; the edge answers 502 Bad Gateway." ;;
    wrong-upstream-port) echo "Layer: L7 edge->backend. nginx proxies to :3011/:3012 where nothing listens -> 502. DEEP=1 diagnose shows the upstream lines." ;;
    wrong-cert)          echo "Layer: L5 TLS. The edge presents a self-signed cert for wrong.test -> verification fails (curl error 60)." ;;
  esac
}
fix() {
  title "FIX: putting everything back to normal"
  run_on mac1 "$CN dns start; $CN dns-record $APP_RECORD_IP" 2>&1 | sed 's/^/     /'
  run_on mac2 "$CN dns start; $CN dns-record $APP_RECORD_IP; $CN edge start; rm -f ~/cn-project/tls/wrong.*" 2>&1 | sed 's/^/     /'
  run_on mac3 "$CN backend start; $CN edge start" 2>&1 | sed 's/^/     /'
  rm -f "$STATE"
  echo "     (waiting 11 s for nginx to re-check the backends...)"; sleep 11
  wait_normal
  step "Check"; hits 4
  echo "  Still a wrong address? Wait ${DNS_TTL} s (DNS cache) or: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
}

case "${1:-}" in
  who) who ;; check) check ;; p1|P1) p1 ;;
  A|a) ext_A ;; B|b) ext_B ;; C|c) ext_C ;; D|d) ext_D ;; E|e) ext_E ;; F|f) ext_F ;;
  break) brk "${2:-}" ;; answer) answer ;; fix) fix ;;
  *) sed -n '2,19p' "$0" ;;
esac
