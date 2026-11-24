#!/bin/bash
# fault-drills.sh - Extension F practice: inject a realistic fault, run
# diagnose.sh, then revert. Run on Satyam's Mac (Mac 1).
# Output -> evidence/phase_2/logs/extF-drills.log
#
#   scripts/phase2/fault-drills.sh          all 8 drills (~6 minutes: DNS drills wait out the TTL)
#   scripts/phase2/fault-drills.sh 3        only drill 3
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"
LOG="$ROOT/evidence/phase_2/logs/extF-drills.log"
SITE='~/cn-project/nginx/cn-project.conf'

diag() { "$ROOT/scripts/diagnose.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\[|OK|FAIL|WARN|>>>|likely|next step|->' ; }
wait_ttl() { echo "  (waiting $((DNS_TTL + 5)) s so this client's cached DNS answer expires)"; sleep $((DNS_TTL + 5)); }
drill() { printf '\n######## DRILL %s: %s  (%s)\n' "$1" "$2" "$(date +%T)"; echo "FAULT INJECTED: $3"; }
both_record() { run_on mac1 "$CN dns-record $1" >/dev/null; run_on mac2 "$CN dns-record $1" >/dev/null; }

d1() { drill 1 "DNS record points to the wrong IP" "app.$TEAM_DOMAIN -> $MAC1_IP (Satyam's Mac, no web server)"
       both_record "$MAC1_IP"; wait_ttl; diag
       both_record "$APP_RECORD_IP"; echo "REVERTED"; wait_ttl; }
d2() { drill 2 "Both DNS resolvers down" "dnsmasq stopped on Mac 1 and Mac 2"
       run_on mac1 "$CN dns stop" >/dev/null; run_on mac2 "$CN dns stop" >/dev/null; wait_ttl; diag
       run_on mac1 "$CN dns start" >/dev/null; run_on mac2 "$CN dns start" >/dev/null; echo "REVERTED"; }
d3() { drill 3 "Edge web server stopped" "nginx stopped on Mac 2 (Krishna)"
       run_on mac2 "$CN edge stop" >/dev/null; diag
       run_on mac2 "$CN edge start" >/dev/null; echo "REVERTED"; }
d4() { drill 4 "Edge listens on the wrong port" "nginx moved from :443 to :8443 on Mac 2"
       run_on mac2 "sed -i '' 's/listen 443 ssl;/listen 8443 ssl;/' $SITE && $CN edge reload" >/dev/null; sleep 1; diag
       run_on mac2 "$CN edge start" >/dev/null; echo "REVERTED (deployed config re-installed)"; }
d5() { drill 5 "Wrong upstream ports in the edge config" "nginx upstreams changed to :3011/:3012"
       run_on mac2 "sed -i '' -e 's/:3001 /:3011 /' -e 's/:3002 /:3012 /' $SITE && $CN edge reload" >/dev/null; sleep 1
       DEEP=1 "$ROOT/scripts/diagnose.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\[|OK|FAIL|WARN|>>>|likely|next step|->|server '
       run_on mac2 "$CN edge start" >/dev/null; echo "REVERTED (deployed config re-installed)"; sleep 11; }
d6() { drill 6 "Edge serves the wrong certificate" "nginx given a self-signed cert for wrong.test"
       run_on mac2 "cd ~/cn-project/tls && openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=wrong.test -keyout wrong.key -out wrong.crt 2>/dev/null && sed -i '' -e 's#tls/app.teamX.test.crt#tls/wrong.crt#' -e 's#tls/app.teamX.test.key#tls/wrong.key#' $SITE && $CN edge reload" >/dev/null; sleep 1; diag
       run_on mac2 "$CN edge start >/dev/null; rm -f ~/cn-project/tls/wrong.*"; echo "REVERTED"; }
d7() { drill 7 "Both backends down" "Flask backends A and B stopped on Mac 3 (Akshit)"
       run_on mac3 "$CN backend stop" >/dev/null; diag
       run_on mac3 "$CN backend start" >/dev/null; echo "REVERTED"; sleep 11; }   # let nginx fail_timeout expire
d8() { drill 8 "One backend down (hidden by failover)" "Backend A stopped on Mac 3"
       run_on mac3 "$CN backend stop A" >/dev/null; diag
       run_on mac3 "$CN backend start A" >/dev/null; echo "REVERTED"; }

{
  echo "Extension F practice drills - $(date) - client $(hostname -s) ($(ipconfig getifaddr en0))"
  echo "Method: diagnose.sh checks L1 network -> L2 DNS -> L3 IP -> L4 TCP -> L5 TLS -> L6 HTTP -> L7 edge->backend and stops at the first failure."
  if [ -n "${1:-}" ]; then "d$1"; else for i in 1 2 3 4 5 6 7 8; do "d$i"; done; fi
  printf '\n######## FINAL HEALTH CHECK (after nginx fail_timeout)\n'; sleep 11; diag
} 2>&1 | tee "$LOG"
echo "log: ${LOG#$ROOT/}"
