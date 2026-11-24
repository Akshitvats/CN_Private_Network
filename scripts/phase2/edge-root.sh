#!/bin/bash
# edge-root.sh - run the PRIMARY edge (nginx on Krishna's Mac, Mac 2) as root.
#
# WHY: macOS (15+) "Local Network privacy" only lets a non-Apple program open
# connections to other machines on the LAN while the SSH session / Terminal
# that started it is still alive - or if it runs as ROOT. nginx is started over
# SSH by deploy.sh, so as a normal user it loses LAN access when that session
# ends and every upstream connect fails with "(65: No route to host)" -> 502.
# (Phase 1 never hit this because nginx ran as root via "sudo brew services".)
# The standby edge on Akshit's Mac is not affected: its backends are on its own IP.
#
# Run ONCE on Krishna's Mac with sudo (from Satyam's Mac:
#   ssh -t krishnaverma@<Krishna IP> 'sudo ~/cn-project/bin/edge-root.sh install'):
#
#   sudo edge-root.sh install     install /usr/local/sbin/cn-edge + /etc/sudoers.d/cn-edge
#   sudo edge-root.sh uninstall   remove both (edge then runs as the normal user again)
#        edge-root.sh status      show whether root mode is installed
#
# /usr/local/sbin/cn-edge is root-owned and can ONLY start / stop / reload / test the
# project nginx with fixed paths. The sudoers rule lets the edge user run exactly that
# helper without a password, so cn.sh, deploy.sh and demo.sh stay fully automated.
# nginx runs as root (master + workers: the workers make the upstream connections).
set -euo pipefail
HELPER=/usr/local/sbin/cn-edge
RULE=/etc/sudoers.d/cn-edge
U="${SUDO_USER:-$(id -un)}"
H="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"; H="${H:-/Users/$U}"
CN_HOME="$H/cn-project"

case "${1:-status}" in
install)
    [ "$(id -u)" = 0 ] || { echo "Run with sudo:  sudo $0 install"; exit 1; }
    [ "$U" != root ] || { echo "Run it with sudo from the edge user's account (SUDO_USER is empty)"; exit 1; }
    mkdir -p /usr/local/sbin
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
#!/bin/bash
# cn-edge - start/stop/reload/test the CN project nginx edge as root.
# Installed by $CN_HOME/bin/edge-root.sh for user $U. Root-owned: do not edit.
set -u
H=$CN_HOME
NGX=(/opt/homebrew/bin/nginx -p "\$H/nginx" -c "\$H/nginx/nginx.conf" -e "\$H/logs/nginx-error.log")
case "\${1:-}" in
    start)  "\${NGX[@]}" ;;
    stop)   "\${NGX[@]}" -s stop ;;
    reload) "\${NGX[@]}" -s reload ;;
    test)   "\${NGX[@]}" -t ;;
    *) echo "usage: cn-edge start|stop|reload|test"; exit 2 ;;
esac
EOF
    install -o root -g wheel -m 755 "$tmp" "$HELPER"; rm -f "$tmp"
    tmp="$(mktemp)"
    printf '# CN project: let %s manage the root nginx edge (scripts/phase2/edge-root.sh)\n%s ALL=(root) NOPASSWD: %s\n' "$U" "$U" "$HELPER" > "$tmp"
    if visudo -cf "$tmp" >/dev/null; then install -o root -g wheel -m 440 "$tmp" "$RULE"; rm -f "$tmp"
    else rm -f "$tmp"; echo "ERROR: sudoers rule failed validation - nothing installed"; rm -f "$HELPER"; exit 1; fi
    echo "INSTALLED: $HELPER (root:wheel 755) and $RULE (user $U may run it without a password)"
    echo "Next (as $U):  ~/cn-project/bin/cn.sh edge restart" ;;
uninstall)
    [ "$(id -u)" = 0 ] || { echo "Run with sudo:  sudo $0 uninstall"; exit 1; }
    [ -x "$HELPER" ] && "$HELPER" stop 2>/dev/null || true
    rm -f "$HELPER" "$RULE"
    echo "REMOVED $HELPER and $RULE - the edge now runs as the normal user (cn.sh edge start)." ;;
status)
    if [ -x "$HELPER" ] && sudo -n -l "$HELPER" >/dev/null 2>&1; then echo "root edge mode: INSTALLED ($HELPER, $RULE)"
    else echo "root edge mode: not installed (run: sudo $0 install)"; exit 1; fi ;;
*) sed -n '2,23p' "$0"; exit 2 ;;
esac
