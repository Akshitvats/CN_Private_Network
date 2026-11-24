#!/bin/bash
# Shared helpers for the operator scripts. Source it from a script in scripts/ or scripts/phase2/:
#
#   source "$(cd "$(dirname "$0")" && pwd -P | sed 's#/scripts.*##')/scripts/lib/common.sh"
#
# Provides: ROOT, team.env variables, colours, and helpers to run commands /
# copy files on any team Mac. The local Mac is detected by IP, so the same
# scripts work from whichever Mac you run them on (normally Satyam's, Mac 1).

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$ROOT/team/team.env"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

APP="app.$TEAM_DOMAIN"
API="api.$TEAM_DOMAIN"
CA="$ROOT/tls/mkcert-rootCA.pem"            # public team CA certificate (Krishna's mkcert CA)
CN='~/cn-project/bin/cn.sh'                   # per-node control script (installed by deploy.sh)
NODES=(mac1 mac2 mac3)

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
LOCAL_IPS=" $(ifconfig 2>/dev/null | awk '/inet /{print $2}' | xargs) "

if [ -t 1 ]; then
    B=$'\e[1m'; C=$'\e[36m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; M=$'\e[35m'; N=$'\e[0m'
else
    B=; C=; G=; Y=; R=; M=; N=
fi

up()        { echo "$1" | tr '[:lower:]' '[:upper:]'; }
node_ip()   { local v; v="$(up "$1")_IP";   echo "${!v}"; }
node_ssh()  { local v; v="$(up "$1")_SSH";  echo "${!v}"; }
node_name() { local v; v="$(up "$1")_NAME"; echo "${!v}"; }
is_local()  { [[ "$LOCAL_IPS" == *" $(node_ip "$1") "* ]]; }

# Human label for an IP: "Krishna's Mac"
who_ip() {
    local n; for n in "${NODES[@]}"; do [ "$(node_ip "$n")" = "$1" ] && { echo "$(node_name "$n")'s Mac"; return; }; done
    echo "$1"
}

run_on() {  # run_on <node> <shell command>      (bash on the target Mac)
    local n="$1"; shift
    if is_local "$n"; then bash -c "$*"; else ssh "${SSH_OPTS[@]}" "$(node_ssh "$n")" "bash -c $(printf '%q' "$*")"; fi
}
run_on_tty() {  # like run_on but with a terminal (for sudo password prompts)
    local n="$1"; shift
    if is_local "$n"; then bash -c "$*"; else ssh -t -o ConnectTimeout=8 -o LogLevel=ERROR "$(node_ssh "$n")" "bash -c $(printf '%q' "$*")"; fi
}
put() {     # put <node> <local file> <path relative to the remote $HOME>
    if is_local "$1"; then mkdir -p "$(dirname "$HOME/$3")"; cp "$2" "$HOME/$3"
    else scp -q "${SSH_OPTS[@]}" "$2" "$(node_ssh "$1"):$3"; fi
}
get() {     # get <node> <path relative to the remote $HOME> <local file>
    if is_local "$1"; then cp "$HOME/$2" "$3"
    else scp -q "${SSH_OPTS[@]}" "$(node_ssh "$1"):$2" "$3"; fi
}

# What THIS Mac's system resolver (mDNSResponder - used by curl and browsers) returns
sysresolve() { dscacheutil -q host -a name "$1" 2>/dev/null | awk '/ip_address/{print $2}' | head -1; }
