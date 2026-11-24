#!/bin/bash
# deploy.sh - push the configuration bundle to every Mac and (re)start services.
# Run on the operator Mac (Satyam, Mac 1); it reaches the other Macs over SSH.
#
#   scripts/deploy.sh             render + copy configs + (re)start everything + status
#   scripts/deploy.sh --tls       also RE-ISSUE the edge certificate with mkcert on Mac 2
#   scripts/deploy.sh --no-start  only copy files
#   scripts/deploy.sh status      status of every Mac
#   scripts/deploy.sh stop        stop every project service on every Mac (end of session)
#
# Each Mac gets a self-contained ~/cn-project/ :
#   bin/  (cn.sh, client-setup.sh, firewall.sh)   team.env  node.env
#   dnsmasq/  nginx/  tls/  backend/  firewall/  logs/  run/  backup/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"
R="$ROOT/config/rendered"
DO_TLS=0; DO_START=1; ACTION=deploy
for a in "$@"; do case "$a" in
    --tls) DO_TLS=1 ;; --no-start) DO_START=0 ;; status|stop) ACTION="$a" ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option $a"; exit 2 ;; esac; done

roles_of() { case "$1" in
    mac1) echo "dns client" ;;
    mac2) echo "edge dns client" ;;
    mac3) echo "backend edge firewall client" ;; esac; }
edge_mode_of() { case "$1" in mac2) echo "$EDGE1_MODE" ;; mac3) echo "$EDGE2_MODE" ;; *) echo user ;; esac; }
label_of() { case "$1" in
    mac1) echo "PRIMARY DNS + test client" ;;
    mac2) echo "PRIMARY EDGE (edge1) + BACKUP DNS" ;;
    mac3) echo "BACKEND A + B + STANDBY EDGE (edge2) + firewall" ;; esac; }

status_all() {
    for n in "${NODES[@]}"; do run_on "$n" "$CN status" 2>&1 || echo "  $(node_name "$n")'s Mac ($(node_ip "$n")): UNREACHABLE"; done
}

preflight() {  # every Mac must answer over SSH, at the IP written in team.env
    local n ip bad=0
    for n in "${NODES[@]}"; do
        ip="$(run_on "$n" 'ipconfig getifaddr en0' 2>/dev/null || true)"
        if [ "$ip" = "$(node_ip "$n")" ]; then echo "  ${G}OK${N}  $(node_name "$n")'s Mac  $(node_ssh "$n")  ($(label_of "$n"))"
        else echo "  ${R}FAIL${N} $(node_name "$n")'s Mac  $(node_ssh "$n")  -> ${ip:-unreachable}"; bad=1; fi
    done
    [ $bad = 0 ] || { echo; echo "IPs changed? Run scripts/get-my-ip.sh on each Mac, then:"; echo "  scripts/update-ips.sh mac2=<Krishna IP> mac3=<Akshit IP>"; exit 1; }
}

case "$ACTION" in
    status) status_all; exit 0 ;;
    stop)   for n in "${NODES[@]}"; do run_on "$n" "$CN down" 2>&1 || true; done; exit 0 ;;
esac

echo "${B}== 1. Checking every Mac is reachable at its team.env address${N}"
preflight

echo "${B}== 2. Rendering configs from team/team.env${N}"
"$ROOT/scripts/render-configs.sh" | sed 's/^/  /'

echo "${B}== 3. Copying the bundle to each Mac${N}"
for n in "${NODES[@]}"; do
    run_on "$n" "mkdir -p ~/cn-project/{bin,dnsmasq,nginx,tls,backend,firewall,logs,run,backup}"
    put "$n" "$ROOT/scripts/phase2/cn.sh"            cn-project/bin/cn.sh
    put "$n" "$ROOT/scripts/phase2/client-setup.sh"  cn-project/bin/client-setup.sh
    put "$n" "$ROOT/team/team.env"                   cn-project/team.env
    put "$n" "$CA"                                   cn-project/tls/mkcert-rootCA.pem
    printf 'NODE=%s\nROLES="%s"\nROLE_LABEL="%s"\nEDGE_MODE=%s\n' "$n" "$(roles_of "$n")" "$(label_of "$n")" "$(edge_mode_of "$n")" > "$R/$n/node.env"
    put "$n" "$R/$n/node.env"                        cn-project/node.env
    echo "  $(node_name "$n")'s Mac: bin/, team.env, node.env, CA cert"
done
# DNS resolvers (primary + backup get the identical zone)
for n in mac1 mac2; do
    put "$n" "$R/$n/dnsmasq.conf" cn-project/dnsmasq/dnsmasq.conf
    put "$n" "$R/$n/teamX.hosts"  cn-project/dnsmasq/teamX.hosts
    echo "  $(node_name "$n")'s Mac: dnsmasq.conf + teamX.hosts ($APP_RECORD_IP, TTL ${DNS_TTL}s)"
done
# Edges (primary + standby get the same site config, different X-Edge label)
for n in mac2 mac3; do
    put "$n" "$R/$n/nginx.conf"       cn-project/nginx/nginx.conf
    put "$n" "$R/$n/cn-project.conf"  cn-project/nginx/cn-project.conf.deployed
    put "$n" "$ROOT/scripts/phase2/edge-root.sh" cn-project/bin/edge-root.sh
    run_on "$n" "cp ~/cn-project/nginx/cn-project.conf.deployed ~/cn-project/nginx/cn-project.conf"
    echo "  $(node_name "$n")'s Mac: nginx.conf + cn-project.conf"
done
# Backends + firewall on Mac 3
put mac3 "$ROOT/backend/app.py"                         cn-project/backend/app.py
put mac3 "$ROOT/backend/requirements.txt"               cn-project/backend/requirements.txt
put mac3 "$ROOT/scripts/phase2/firewall.sh"             cn-project/bin/firewall.sh
put mac3 "$R/mac3/pf-backend-isolation.conf"            cn-project/firewall/pf-backend-isolation.conf
run_on mac3 'cd ~/cn-project/backend && PY=/usr/bin/python3; [ -x $PY ] || PY=python3
    [ -x .venv/bin/python ] || $PY -m venv .venv
    .venv/bin/python -c "import flask" 2>/dev/null || .venv/bin/pip install -q --disable-pip-version-check -r requirements.txt
    echo "  Akshit'"'"'s Mac: backend app.py, venv ($(.venv/bin/python -c "import flask,sys; print(\"python\", sys.version.split()[0], \"flask\", flask.__version__)" 2>/dev/null)), pf rules"'
for n in "${NODES[@]}"; do run_on "$n" "chmod +x ~/cn-project/bin/*.sh"; done

echo "${B}== 4. Edge TLS certificate (same cert + key on both edges)${N}"
# Mac 2 owns the CA (mkcert). Phase 1 cert lives in ~/cn-tls; reuse it unless --tls.
run_on mac2 "export PATH=/opt/homebrew/bin:\$PATH; cd ~/cn-project/tls
    if [ $DO_TLS = 1 ] || [ ! -s app.teamX.test.key ]; then
        if [ $DO_TLS = 0 ] && [ -s ~/cn-tls/app.teamX.test+2.pem ]; then
            cp ~/cn-tls/app.teamX.test+2.pem app.teamX.test.crt; cp ~/cn-tls/app.teamX.test+2-key.pem app.teamX.test.key
            echo '  reused Phase 1 certificate from ~/cn-tls'
        else
            mkcert -cert-file app.teamX.test.crt -key-file app.teamX.test.key app.$TEAM_DOMAIN api.$TEAM_DOMAIN 2>&1 | grep -iE 'created|error' | sed 's/^/  /'
        fi
        chmod 600 app.teamX.test.key
    fi
    openssl x509 -in app.teamX.test.crt -noout -subject -ext subjectAltName -enddate | sed 's/^/  /'"
get mac2 cn-project/tls/app.teamX.test.crt "$ROOT/tls/app.teamX.test.crt"   # public cert, for the repo
# The standby edge must present the same certificate, so it gets the key too.
# It is copied host-to-host through a private temp dir and never stored in the repo.
TMPK="$(mktemp -d)"; chmod 700 "$TMPK"; trap 'rm -rf "$TMPK"' EXIT
get mac2 cn-project/tls/app.teamX.test.key "$TMPK/k"
put mac3 "$TMPK/k" cn-project/tls/app.teamX.test.key
put mac3 "$ROOT/tls/app.teamX.test.crt" cn-project/tls/app.teamX.test.crt
run_on mac3 "chmod 600 ~/cn-project/tls/app.teamX.test.key"
rm -rf "$TMPK"
echo "  certificate + key installed on Krishna's Mac (edge1) and Akshit's Mac (edge2)"

if [ "$DO_START" = 1 ]; then
    echo "${B}== 5. Starting services (backends -> DNS -> edges)${N}"
    run_on mac3 "$CN backend start"
    run_on mac1 "$CN dns restart"
    run_on mac2 "$CN dns restart"
    if [ "$EDGE1_MODE" = root ] && ! run_on mac2 "~/cn-project/bin/edge-root.sh status" >/dev/null 2>&1; then
        echo "  ${Y}edge1 needs root mode (macOS Local Network privacy - see scripts/phase2/edge-root.sh). Run ONCE:${N}"
        echo "    ssh -t $MAC2_SSH 'sudo ~/cn-project/bin/edge-root.sh install'     (Krishna's password)"
        echo "  then: scripts/deploy.sh"
    else
        run_on mac2 "$CN edge restart"
    fi
    run_on mac3 "$CN edge start"
    echo "${B}== 6. Status${N}"
    status_all
    echo
    echo "Next: scripts/smoke-test.sh   (or scripts/demo.sh check)"
fi
