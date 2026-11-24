#!/bin/bash
# client-setup.sh - one-time CLIENT setup. Run ON EACH client Mac with sudo:
#
#   sudo scripts/phase2/client-setup.sh            configure this Mac as a team client
#   sudo scripts/phase2/client-setup.sh --undo     restore the previous DNS settings
#   (deploy.sh also installs it as ~/cn-project/bin/client-setup.sh on every Mac)
#
# 1. Sets the Wi-Fi DNS servers to  <primary DNS, Mac 1>  <backup DNS, Mac 2>
#    (Phase 1 Task B + Phase 2 Extension A: clients list BOTH resolvers).
#    dnsmasq forwards non-project names upstream, so normal Internet still works.
# 2. Moves away /etc/resolver/<teamX.test|test> (Phase 1 leftover that sends
#    *.teamX.test ONLY to 127.0.0.1 - it would bypass the backup resolver).
# 3. Trusts the team CA (Krishna's mkcert root) in the System keychain so curl
#    and browsers validate https://app.teamX.test without -k (Task E).
# 4. Flushes the macOS DNS cache.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/../node.env" ]; then          # installed copy: ~/cn-project/bin/
    BASE="$(cd "$HERE/.." && pwd)"; ENVF="$BASE/team.env"; STATE="$BASE/backup/client-state"
else                                          # repo copy: scripts/phase2/
    BASE="$(cd "$HERE/../.." && pwd)"; ENVF="$BASE/team/team.env"; STATE="$BASE/config/client-state"
fi
CAF="$BASE/tls/mkcert-rootCA.pem"
# shellcheck disable=SC1090
source "$ENVF"
[ "$(id -u)" = 0 ] || { echo "Run with sudo:  sudo $0 $*"; exit 1; }
mkdir -p "$STATE"
SVC="$(networksetup -listallnetworkservices | grep -m1 -E '^Wi-?Fi$' || echo Wi-Fi)"

flush() { dscacheutil -flushcache; killall -HUP mDNSResponder; }

if [ "${1:-}" = "--undo" ]; then
    prev="$(cat "$STATE/dns-before.txt" 2>/dev/null || echo Empty)"
    # shellcheck disable=SC2086
    networksetup -setdnsservers "$SVC" $prev
    for f in "$STATE"/resolver.*; do
        [ -f "$f" ] || continue
        mkdir -p /etc/resolver; cp "$f" "/etc/resolver/${f##*/resolver.}"; echo "Restored /etc/resolver/${f##*/resolver.}"
    done
    flush
    echo "Restored DNS for $SVC: $(networksetup -getdnsservers "$SVC" | xargs)"
    exit 0
fi

# 1. DNS servers: primary + backup
cur="$(networksetup -getdnsservers "$SVC")"
[[ "$cur" == *"any DNS Servers"* ]] && cur="Empty"
[ -f "$STATE/dns-before.txt" ] || { echo "$cur" | xargs > "$STATE/dns-before.txt"; echo "Saved previous DNS ($(echo "$cur" | xargs)) to $STATE/dns-before.txt"; }
networksetup -setdnsservers "$SVC" "$DNS1_IP" "$DNS2_IP"
echo "DNS servers for $SVC: $(networksetup -getdnsservers "$SVC" | xargs)   (primary = $MAC1_NAME, backup = $MAC2_NAME)"

# 2. Phase 1 per-domain resolver override
dl="$(echo "$TEAM_DOMAIN" | tr '[:upper:]' '[:lower:]')"
for f in /etc/resolver/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
    if [ "$b" = "$dl" ] || [ "$b" = "${dl##*.}" ]; then
        cp "$f" "$STATE/resolver.$(basename "$f")"; rm "$f"
        echo "Moved away $f (it pinned *.$TEAM_DOMAIN to $(awk '/nameserver/{print $2}' "$STATE/resolver.$(basename "$f")" | xargs)); backup in $STATE/"
    fi
done

# 3. Trust the team CA
if security verify-cert -c "$CAF" >/dev/null 2>&1; then
    echo "Team CA already trusted: $(openssl x509 -in "$CAF" -noout -subject | sed 's/.*CN=//')"
else
    security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CAF"
    echo "Trusted team CA: $(openssl x509 -in "$CAF" -noout -subject | sed 's/.*CN=//')"
fi

# 4. Flush
flush
echo "DNS cache flushed."
echo
echo "Check:"
echo "  dig app.$TEAM_DOMAIN                         # SERVER: $DNS1_IP, answer $APP_RECORD_IP"
echo "  curl -sI https://app.$TEAM_DOMAIN/api/status   # no -k needed, HTTP/2 200"
