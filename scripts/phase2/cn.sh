#!/bin/bash
# cn.sh - per-Mac service control for the CN project. No interactive sudo needed.
# Installed as ~/cn-project/bin/cn.sh on every Mac by scripts/deploy.sh.
#
#   cn.sh dns start|stop|restart|reload|status     dnsmasq   (Mac 1 primary, Mac 2 backup)
#   cn.sh dns-record <ip>                           point app/api.teamX.test at <ip> + reload
#   cn.sh edge start|stop|restart|reload|status     nginx     (Mac 2 primary, Mac 3 standby)
#   cn.sh backend start|stop|status [A|B]           Flask backends (Mac 3)
#   cn.sh up | down                                 start / stop every service of this Mac's roles
#   cn.sh status                                    everything on this Mac
#
# "edge start/restart" always re-installs the config exactly as deployed
# (undoing any injected fault); "edge reload" reloads the file as it is now.
# EDGE_MODE=root (node.env, Krishna's Mac): nginx runs as root through the
# helper installed by edge-root.sh - see that file for why (macOS Local Network privacy).
set -uo pipefail
CN_HOME="${CN_HOME:-$HOME/cn-project}"
# shellcheck disable=SC1091
[ -f "$CN_HOME/team.env" ] && source "$CN_HOME/team.env"
# shellcheck disable=SC1091
[ -f "$CN_HOME/node.env" ] && source "$CN_HOME/node.env"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/sbin:/usr/bin:/bin:/sbin:$PATH"
DNSMASQ=/opt/homebrew/sbin/dnsmasq
NGINX=/opt/homebrew/bin/nginx
NGX=("$NGINX" -p "$CN_HOME/nginx" -c "$CN_HOME/nginx/nginx.conf" -e "$CN_HOME/logs/nginx-error.log")
EDGE_HELPER=/usr/local/sbin/cn-edge
mkdir -p "$CN_HOME"/{logs,run,backup} "$CN_HOME/run/nginx-tmp"

say()   { echo "[$(date '+%H:%M:%S') $(hostname -s)] $*"; }
alive() { [ -f "$1" ] && ps -p "$(cat "$1" 2>/dev/null)" >/dev/null 2>&1; }   # works for root-owned pids too
listener() { lsof -t -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1 | grep .; }
has_role() { [[ " ${ROLES:-} " == *" $1 "* ]]; }

# ------------------------------------------------------------------ DNS
dns() {
    local pid="$CN_HOME/run/dnsmasq.pid" conf="$CN_HOME/dnsmasq/dnsmasq.conf"
    case "${1:-status}" in
    start)
        if alive "$pid"; then say "dnsmasq already running (pid $(cat "$pid"))"; return 0; fi
        [ -x "$DNSMASQ" ] || { say "dnsmasq not installed (brew install dnsmasq)"; return 1; }
        local err
        err="$("$DNSMASQ" --test --conf-file="$conf" 2>&1)" || { say "dnsmasq config test FAILED: $err"; return 1; }
        err="$("$DNSMASQ" --conf-file="$conf" 2>&1)"
        sleep 0.5
        if alive "$pid"; then say "dnsmasq STARTED (pid $(cat "$pid")) on udp/tcp 0.0.0.0:53"
        else say "dnsmasq FAILED to start: ${err:-see $CN_HOME/logs/dnsmasq.log}"; return 1; fi ;;
    stop)
        if alive "$pid"; then kill "$(cat "$pid")"; sleep 0.3; say "dnsmasq STOPPED"; else say "dnsmasq not running"; fi
        rm -f "$pid" ;;
    restart) dns stop; dns start ;;
    reload)
        alive "$pid" || { say "dnsmasq not running"; return 1; }
        kill -HUP "$(cat "$pid")"
        say "dnsmasq RELOADED (SIGHUP: re-read teamX.hosts, cache cleared)" ;;
    status)
        if alive "$pid"; then say "dnsmasq UP   (pid $(cat "$pid"))  records: $(grep -v '^#' "$CN_HOME/dnsmasq/teamX.hosts" | xargs)"
        else say "dnsmasq DOWN"; fi ;;
    *) echo "usage: cn.sh dns start|stop|restart|reload|status"; return 2 ;;
    esac
}

dns_record() {
    local ip="${1:?usage: cn.sh dns-record <ip>}" f="$CN_HOME/dnsmasq/teamX.hosts"
    local domain="${TEAM_DOMAIN:-teamX.test}"
    { grep '^#' "$f"; echo "$ip app.$domain api.$domain"; } > "$f.new" && mv "$f.new" "$f"
    say "record app.$domain / api.$domain -> $ip"
    dns reload
}

# ------------------------------------------------------------------ EDGE (nginx)
is_root_mode() { [ "${EDGE_MODE:-user}" = root ]; }
ngx() {  # ngx start|stop|reload|test   - in the right mode
    if is_root_mode; then sudo -n "$EDGE_HELPER" "$1"
    else case "$1" in start) "${NGX[@]}" ;; test) "${NGX[@]}" -t ;; *) "${NGX[@]}" -s "$1" ;; esac; fi
}
edge() {
    local pid="$CN_HOME/run/nginx.pid" site="$CN_HOME/nginx/cn-project.conf" t
    if is_root_mode && [ "${1:-status}" != status ] && ! sudo -n -l "$EDGE_HELPER" >/dev/null 2>&1; then
        say "root edge mode is not installed on this Mac. Run once:  sudo ~/cn-project/bin/edge-root.sh install"
        return 1
    fi
    case "${1:-status}" in
    start|restart)
        [ -x "$NGINX" ] || { say "nginx not installed (brew install nginx)"; return 1; }
        # Re-install the deployed config (undoes any injected fault).
        [ -f "$site.deployed" ] && cp "$site.deployed" "$site"
        # Create the logs as the normal user so they stay readable/writable in both modes.
        touch "$CN_HOME/logs/nginx-error.log" "$CN_HOME/logs/nginx-access.log"
        if [ "$1" = restart ] && alive "$pid"; then ngx stop 2>/dev/null; for _ in $(seq 1 15); do alive "$pid" || break; sleep 0.2; done; fi
        edge reload ;;
    reload)
        t="$(ngx test 2>&1)" || { say "nginx config test FAILED:"; echo "$t" | grep -vE 'the "user" directive|test failed' | sed 's/^/    /'; return 1; }
        if alive "$pid"; then ngx reload 2>/dev/null; sleep 0.3; say "nginx RELOADED (pid $(cat "$pid"))"
        else
            t="$(ngx start 2>&1)"; sleep 0.5
            if alive "$pid"; then say "nginx STARTED (pid $(cat "$pid")$(is_root_mode && echo ', root master'))  on :80 and :443"
            else
                say "nginx FAILED to start: $(echo "$t" | grep -v 'the "user" directive' | sort -u | head -3)"
                if [[ "$t" == *"Address already in use"* ]]; then
                    say "another process holds :80/:443 -> $(pgrep -lf 'nginx: master' | head -1)"
                    say "if it is the Phase 1 root nginx, stop it once with:  sudo brew services stop nginx"
                fi
                return 1
            fi
        fi ;;
    stop)
        if alive "$pid"; then ngx stop 2>/dev/null; for _ in $(seq 1 15); do alive "$pid" || break; sleep 0.2; done
            alive "$pid" && { say "nginx did NOT stop (pid $(cat "$pid"))"; return 1; }
            say "nginx STOPPED"
        else say "nginx not running"; fi ;;
    status)
        if alive "$pid"; then
            local ports=""; nc -z -G 1 127.0.0.1 80 2>/dev/null && ports+=":80 "; nc -z -G 1 127.0.0.1 443 2>/dev/null && ports+=":443"
            say "nginx UP     (pid $(cat "$pid"), master runs as $(ps -o user= -p "$(cat "$pid")" | xargs))  listening: ${ports:-none}"
        else say "nginx DOWN"; fi ;;
    *) echo "usage: cn.sh edge start|stop|restart|reload|status"; return 2 ;;
    esac
}

# ------------------------------------------------------------------ BACKENDS
backend() {
    local action="${1:-status}" id="${2:-}"
    if [ -z "$id" ]; then for b in A B; do backend "$action" "$b"; done; return; fi
    local port; case "$id" in A|a) id=A; port=3001 ;; B|b) id=B; port=3002 ;; *) echo "backend id must be A or B"; return 2 ;; esac
    case "$action" in
    start)
        if listener "$port" >/dev/null; then say "backend $id already running on :$port"; return 0; fi
        [ -x "$CN_HOME/backend/.venv/bin/python" ] || { say "backend venv missing - run scripts/deploy.sh"; return 1; }
        # exec: no helper shell stays behind; all fds go to the log so SSH callers return at once.
        ( cd "$CN_HOME/backend" && BACKEND_ID="$id" PORT="$port" exec nohup .venv/bin/python app.py ) \
            </dev/null >> "$CN_HOME/logs/backend-$id.log" 2>&1 &
        disown 2>/dev/null || true
        for _ in $(seq 1 20); do listener "$port" >/dev/null && break; sleep 0.3; done
        if listener "$port" > "$CN_HOME/run/backend-$id.pid"; then say "backend $id STARTED on 0.0.0.0:$port (pid $(cat "$CN_HOME/run/backend-$id.pid"))"
        else say "backend $id FAILED:"; tail -5 "$CN_HOME/logs/backend-$id.log"; return 1; fi ;;
    stop)
        local p; p="$(listener "$port")"
        if [ -n "$p" ]; then kill "$p"; for _ in $(seq 1 15); do listener "$port" >/dev/null || break; sleep 0.2; done
            say "backend $id STOPPED (port $port closed)"
        else say "backend $id not running"; fi
        rm -f "$CN_HOME/run/backend-$id.pid" ;;
    status)
        local p; p="$(listener "$port")"
        if [ -n "$p" ]; then say "backend $id UP  (pid $p) on :$port"; else say "backend $id DOWN"; fi ;;
    *) echo "usage: cn.sh backend start|stop|status [A|B]"; return 2 ;;
    esac
}

case "${1:-status}" in
    dns)        shift; dns "$@" ;;
    dns-record) shift; dns_record "$@" ;;
    edge)       shift; edge "$@" ;;
    backend)    shift; backend "$@" ;;
    up)
        has_role backend && backend start
        has_role dns     && dns start
        has_role edge    && edge start
        true ;;
    down)
        has_role edge    && edge stop
        has_role dns     && dns stop
        has_role backend && backend stop
        true ;;
    status)
        say "node=${NODE:-?}  roles: ${ROLES:-?}"
        has_role dns     && dns status
        has_role edge    && edge status
        has_role backend && backend status
        true ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
esac
