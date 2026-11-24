#!/bin/bash
# Render every Mac's configuration from team/team.env into config/rendered/.
#
#   mac1/  Satyam  - primary DNS         : dnsmasq.conf, teamX.hosts
#   mac2/  Krishna - edge1 + backup DNS  : dnsmasq.conf, teamX.hosts, nginx.conf, cn-project.conf
#   mac3/  Akshit  - backends + edge2    : nginx.conf, cn-project.conf, pf-backend-isolation.conf
#
# Usage: scripts/render-configs.sh          (deploy.sh calls it automatically)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/team/team.env"
OUT="$ROOT/config/rendered"
rm -rf "$OUT"; mkdir -p "$OUT"/mac1 "$OUT"/mac2 "$OUT"/mac3

home_of() { echo "/Users/$1/cn-project"; }

UPSTREAM_LINES=""
for s in $UPSTREAM_DNS; do UPSTREAM_LINES+="server=$s"$'\n'; done
UPSTREAM_LINES="${UPSTREAM_LINES%$'\n'}"

rev() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo "$d.$c.$b.$a.in-addr.arpa"; }
PTR_LINES="ptr-record=$(rev "$MAC1_IP"),$MAC1_HOST
ptr-record=$(rev "$MAC2_IP"),$MAC2_HOST
ptr-record=$(rev "$MAC3_IP"),$MAC3_HOST"

render() {  # render <template> <out> KEY=VALUE...   (replaces @KEY@ placeholders)
    local tpl="$1" out="$2"; shift 2
    local text kv k v
    text="$(cat "$tpl")"
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        text="${text//@${k}@/$v}"
    done
    if grep -q '@[A-Z_0-9]*@' <<<"$text"; then
        echo "unrendered placeholder in $out:" >&2; grep -o '@[A-Z_0-9]*@' <<<"$text" >&2; exit 1
    fi
    printf '%s\n' "$text" > "$out"
}

hosts_file() {  # the project zone - identical on both resolvers
    cat > "$1" <<EOF
# Project zone for $TEAM_DOMAIN - served by BOTH dnsmasq resolvers (Mac 1 + Mac 2).
# Change with: ~/cn-project/bin/cn.sh dns-record <ip>   (rewrites this line + SIGHUP)
$APP_RECORD_IP app.$TEAM_DOMAIN api.$TEAM_DOMAIN
EOF
}

user_line() { if [ "$1" = root ]; then echo "user root wheel;"; else echo "# (no \"user\" directive: nginx runs as the normal user)"; fi; }

dns_common=(TEAM_DOMAIN="$TEAM_DOMAIN" DNS_TTL="$DNS_TTL" UPSTREAM_SERVER_LINES="$UPSTREAM_LINES" PTR_RECORD_LINES="$PTR_LINES")
edge_common=(TEAM_DOMAIN="$TEAM_DOMAIN" BACKEND_A="$BACKEND_A" BACKEND_B="$BACKEND_B")

# ---- Mac 1 (Satyam): primary DNS
render "$ROOT/dnsmasq/dnsmasq.conf.template" "$OUT/mac1/dnsmasq.conf" \
    "${dns_common[@]}" DNS_ROLE=primary NODE_IP="$MAC1_IP" CN_HOME="$(home_of "$MAC1_USER")"
hosts_file "$OUT/mac1/teamX.hosts"

# ---- Mac 2 (Krishna): backup DNS + primary edge
render "$ROOT/dnsmasq/dnsmasq.conf.template" "$OUT/mac2/dnsmasq.conf" \
    "${dns_common[@]}" DNS_ROLE=backup NODE_IP="$MAC2_IP" CN_HOME="$(home_of "$MAC2_USER")"
hosts_file "$OUT/mac2/teamX.hosts"
render "$ROOT/nginx/nginx-main.conf.template" "$OUT/mac2/nginx.conf" USER_LINE="$(user_line "$EDGE1_MODE" "$MAC2_USER")" \
    EDGE_NAME=edge1-mac2 NODE_IP="$MAC2_IP" CN_HOME="$(home_of "$MAC2_USER")"
render "$ROOT/nginx/nginx.conf.template" "$OUT/mac2/cn-project.conf" \
    "${edge_common[@]}" EDGE_NAME=edge1-mac2 NODE_IP="$MAC2_IP" CN_HOME="$(home_of "$MAC2_USER")"

# ---- Mac 3 (Akshit): standby edge (same config, different label) + backend firewall
render "$ROOT/nginx/nginx-main.conf.template" "$OUT/mac3/nginx.conf" USER_LINE="$(user_line "$EDGE2_MODE" "$MAC3_USER")" \
    EDGE_NAME=edge2-mac3 NODE_IP="$MAC3_IP" CN_HOME="$(home_of "$MAC3_USER")"
render "$ROOT/nginx/nginx.conf.template" "$OUT/mac3/cn-project.conf" \
    "${edge_common[@]}" EDGE_NAME=edge2-mac3 NODE_IP="$MAC3_IP" CN_HOME="$(home_of "$MAC3_USER")"
render "$ROOT/firewall/pf-backend-isolation.conf.template" "$OUT/mac3/pf-backend-isolation.conf" \
    NODE_IP="$MAC3_IP" EDGE1_IP="$EDGE1_IP"

echo "Rendered into ${OUT#$ROOT/}/ from team/team.env:"
(cd "$OUT" && find . -type f | sort | sed 's#^\./#  #')
