#!/usr/bin/env bash
# Phase 1 evidence run (Mac 1). Runs each task's commands in turn and pauses
# so each screen can be captured. Output is also saved to evidence/phase_1/terminal-output.txt
# Usage: ./scripts/phase1-evidence.sh [pause_seconds] [tasks...]   e.g. ./scripts/phase1-evidence.sh 40 C E
cd "$(dirname "$0")/.." || exit 1
source team/team.env
D=app.${TEAM_DOMAIN}; P=${1:-12}; shift; TASKS="${*:-A B C E D F G}"
OUT=evidence/phase_1/terminal-output.txt; [ $# -eq 0 ] && [ -z "$*" ] ; : >> "$OUT"
sec() { clear; echo "=== $1 ==="; echo "=== $1 ===" >> "$OUT"; }
run() { echo "\$ $*"; echo "\$ $*" >> "$OUT"; eval "$*" 2>&1 | tee -a "$OUT"; echo; }
hold() { sleep "$P"; }

if [[ " $TASKS " == *" A "* ]]; then
sec "Task A: Private LAN (Mac 1)"
run "ipconfig getifaddr en0"
run "ifconfig en0 | grep -E 'inet |ether'"
run "route -n get default | grep -E 'gateway|interface'"
run "ping -c 3 $MAC2_IP"
run "ping -c 3 $MAC3_IP"
hold
fi
if [[ " $TASKS " == *" B "* ]]; then
sec "Task B: Private DNS"
run "dig @$MAC1_IP $D"
run "dig @$MAC1_IP api.${TEAM_DOMAIN} +short"
run "dig @8.8.8.8 $D | grep -E 'status|ANSWER:'"
hold
fi
if [[ " $TASKS " == *" C "* ]]; then
sec "Task C: Backends direct"
run "curl -si http://$BACKEND_A/api/status | grep -E 'HTTP|X-Backend|backend'"
run "curl -si http://$BACKEND_B/api/status | grep -E 'HTTP|X-Backend|backend'"
hold
fi
if [[ " $TASKS " == *" E "* ]]; then
sec "Task E: HTTPS / TLS (no -k)"
run "curl -sv https://$D/api/status 2>&1 | grep -E 'Connected|TLSv|ALPN|subject|issuer|verify|HTTP/'"
hold
fi
if [[ " $TASKS " == *" D "* ]]; then
sec "Task D: Load balancing (round-robin)"
run "for i in 1 2 3 4 5 6; do curl -si https://$D/api/status | grep -i x-backend; done"
hold
fi
if [[ " $TASKS " == *" F "* ]]; then
sec "Task F: Caching"
run "curl -sI https://$D/api/cache"
run "curl -si -H 'If-None-Match: \"cn-cache-v1\"' https://$D/api/cache | head -8"
hold
fi
if [[ " $TASKS " == *" G "* ]]; then
sec "Task G: Packet capture traffic (TLS 1.2, ports)"
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
run "dig @$MAC1_IP $D +short"
run "curl --tlsv1.2 --tls-max 1.2 -sv https://$D/api/status 2>&1 | grep -E 'Trying|Connected|TLSv|HTTP/|X-Backend|backend'"
hold
fi
echo "Done. Saved: $OUT"
