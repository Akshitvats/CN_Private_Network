#!/bin/bash
# update-ips.sh - the IPs changed (new month / new DHCP lease)? Fix everything in one go.
# Run on Satyam's Mac (Mac 1).
#
#   scripts/update-ips.sh                               check the IPs in team.env, auto-detect Mac 1
#   scripts/update-ips.sh mac2=10.7.20.5 mac3=10.7.9.40 set Krishna's / Akshit's new IPs
#   scripts/update-ips.sh ... --deploy                  ... and run deploy.sh afterwards
#
# How to get the teammates' IPs: they run scripts/get-my-ip.sh (or
# "ipconfig getifaddr en0") and send it to you. (Bonjour/.local names do not
# work on the college Wi-Fi - multicast is blocked - so the IP must be given.)
#
# For every Mac it checks over SSH that the address really is that teammate's
# Mac (right user + the Mac reports the same IP), then rewrites the MACn_IP
# lines in team/team.env and re-renders every config.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENVF="$ROOT/team/team.env"
# shellcheck disable=SC1090
source "$ENVF"
DEPLOY=0
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; B=; N=; fi

for a in "$@"; do
    case "$a" in
        --deploy) DEPLOY=1 ;;
        mac[123]=*)
            ip="${a#*=}"
            [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not an IPv4 address: $ip"; exit 2; }
            eval "NEW_${a%%=*}=$ip" ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown argument: $a"; exit 2 ;;
    esac
done

# Mac 1 = this Mac (the operator): detect automatically
IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
NEW_mac1="${NEW_mac1:-$(ipconfig getifaddr "${IF:-en0}")}"
NEW_mac2="${NEW_mac2:-$MAC2_IP}"
NEW_mac3="${NEW_mac3:-$MAC3_IP}"

fail=0
for n in mac1 mac2 mac3; do
    u="$(echo "$n" | tr a-z A-Z)"; userv="${u}_USER"; namev="${u}_NAME"; oldv="${u}_IP"; newv="NEW_$n"
    user="${!userv}"; name="${!namev}"; old="${!oldv}"; new="${!newv}"
    if [ "$n" = mac1 ]; then seen="$new"
    else seen="$(ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR "$user@$new" 'ipconfig getifaddr en0' 2>/dev/null)"; fi
    if [ "$seen" = "$new" ]; then
        printf '  %sOK%s   %-8s %-14s %s\n' "$G" "$N" "$name" "$new" "$([ "$old" != "$new" ] && echo "(was $old)")"
        sed -i '' "s/^${u}_IP=.*/${u}_IP=$new/" "$ENVF"
    else
        printf '  %sFAIL%s %-8s %-14s SSH as %s failed - wrong IP? (ask %s to run scripts/get-my-ip.sh)\n' "$R" "$N" "$name" "$new" "$user" "$name"
        fail=1
    fi
done
sed -i '' "s/^# Last verified: [0-9-]*/# Last verified: $(date +%F)/" "$ENVF"

[ $fail = 0 ] || { echo; echo "Fix the failing IP(s) and run again: scripts/update-ips.sh mac2=<ip> mac3=<ip>"; exit 1; }
echo
"$ROOT/scripts/render-configs.sh" >/dev/null && echo "team/team.env updated and configs re-rendered (config/rendered/)."
# shellcheck disable=SC1090
source "$ENVF"
echo "  DNS1 $DNS1_IP | DNS2 $DNS2_IP | edge1 $EDGE1_IP | edge2 $EDGE2_IP | backends $BACKEND_A $BACKEND_B"
echo
echo "${B}Remember:${N} clients that ran client-setup.sh point at the OLD DNS IPs."
echo "  On each client Mac run again:  sudo scripts/phase2/client-setup.sh   (or ~/cn-project/bin/client-setup.sh)"
if [ $DEPLOY = 1 ]; then "$ROOT/scripts/deploy.sh"; else echo "Next: scripts/deploy.sh"; fi
