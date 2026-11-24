#!/bin/bash
# firewall.sh - Extension C: backend service isolation with pf.
# Runs ON THE BACKEND MAC (Mac 3, Akshit) with sudo. deploy.sh installs it as
# ~/cn-project/bin/firewall.sh; from Satyam's Mac use  scripts/demo.sh C
# (or: ssh -t akshitvats@<ip> sudo ~/cn-project/bin/firewall.sh apply).
#
#   sudo firewall.sh apply      save a rollback copy of the pf state, load our anchor, enable pf
#   sudo firewall.sh status     show our rules with live packet counters
#   sudo firewall.sh rollback   flush our anchor and release our pf reference (original state)
#
# Rules: ~/cn-project/firewall/pf-backend-isolation.conf - only the edge may reach 3001/3002.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/../node.env" ]; then BASE="$(cd "$HERE/.." && pwd)"; RULES="$BASE/firewall/pf-backend-isolation.conf"; STATE="$BASE/backup/firewall-state"
else BASE="$(cd "$HERE/../.." && pwd)"; RULES="$BASE/config/rendered/mac3/pf-backend-isolation.conf"; STATE="$BASE/config/firewall-state"; fi
ANCHOR="com.apple/cn-backend-isolation"
[ "$(id -u)" = 0 ] || { echo "Run with sudo:  sudo $0 $*"; exit 1; }
mkdir -p "$STATE"

case "${1:-status}" in
apply)
    # Rollback copy of the ORIGINAL configuration (taken once, before our first change).
    if [ ! -f "$STATE/pf-before.status" ]; then
        pfctl -sr 2>/dev/null > "$STATE/pf-before.rules" || true
        pfctl -s info 2>/dev/null | head -1 > "$STATE/pf-before.status" || true
        cp /etc/pf.conf "$STATE/etc-pf.conf.bak"
        echo "Saved rollback copy of the original pf state in $STATE/"
    fi
    [ -f "$RULES" ] || { echo "ERROR: $RULES missing - run scripts/deploy.sh"; exit 1; }
    pfctl -a "$ANCHOR" -nf "$RULES" 2>&1 | grep -v -E 'ALTQ|^$' || true     # syntax check (prints only errors)
    pfctl -a "$ANCHOR" -f "$RULES" 2>&1 | grep -v -E 'ALTQ|flushing of rules|^$' || true
    # -E takes a reference on pf; keep the token so rollback releases only ours.
    if [ ! -s "$STATE/pf-token" ]; then { pfctl -E 2>&1 || true; } | awk '/Token/{print $NF}' > "$STATE/pf-token"; fi
    n="$(pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -c . || true)"
    if [ "${n:-0}" -ge 3 ]; then
        echo "APPLIED: $n rules in anchor $ANCHOR  (pf $(pfctl -s info 2>/dev/null | head -1 | awk '{print $2}'))"
        pfctl -a "$ANCHOR" -sr 2>/dev/null
        pfctl -sr 2>/dev/null | grep -q 'anchor "com.apple/\*"' || echo "WARNING: main ruleset does not reference com.apple/* - rules may not be evaluated"
    else
        echo "ERROR: rules did NOT load (anchor has ${n:-0} rules). Rules file: $RULES"; exit 1
    fi ;;
status)
    pfctl -s info 2>/dev/null | head -1
    echo "--- anchor $ANCHOR (with counters):"
    pfctl -a "$ANCHOR" -vsr 2>/dev/null ;;
rollback)
    pfctl -a "$ANCHOR" -F all 2>/dev/null || true
    if [ -s "$STATE/pf-token" ]; then pfctl -X "$(cat "$STATE/pf-token")" 2>/dev/null || true; rm -f "$STATE/pf-token"; fi
    cmp -s /etc/pf.conf "$STATE/etc-pf.conf.bak" 2>/dev/null || echo "WARNING: /etc/pf.conf differs from the backup"
    echo "ROLLED BACK: anchor now has $(pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -c . || true) rules"
    echo "pf now:      $(pfctl -s info 2>/dev/null | head -1)"
    echo "pf before:   $(cat "$STATE/pf-before.status" 2>/dev/null)" ;;
*) echo "usage: sudo $0 apply|status|rollback"; exit 2 ;;
esac
