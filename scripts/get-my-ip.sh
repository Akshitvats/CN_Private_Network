#!/bin/bash
# get-my-ip.sh - Task A inventory for THIS Mac: interface, IPv4/prefix, mask,
# gateway, MAC address, DNS servers. Run it on every Mac at the start of each
# session (college Wi-Fi DHCP hands out new addresses) and send the IP to Satyam.
IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | grep -v utun | head -1)"; IF="${IF:-en0}"
IP="$(ipconfig getifaddr "$IF" 2>/dev/null)"
MASK_HEX="$(ifconfig "$IF" 2>/dev/null | awk '/inet /{print $4}')"      # e.g. 0xffffe000
MASK=""; PREFIX=0
if [ -n "$MASK_HEX" ]; then
    m=$((MASK_HEX))
    MASK="$(( (m>>24)&255 )).$(( (m>>16)&255 )).$(( (m>>8)&255 )).$(( m&255 ))"
    while [ $m -gt 0 ]; do PREFIX=$(( PREFIX + (m & 1) )); m=$(( m >> 1 )); done
fi
echo "Host:        $(hostname -s)  (user: $(whoami))"
echo "Interface:   $IF"
echo "IPv4:        ${IP:-none}/$PREFIX   (mask $MASK)"
echo "Gateway:     $(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
echo "MAC address: $(ifconfig "$IF" 2>/dev/null | awk '/ether/{print $2}')"
echo "DNS servers: $(networksetup -getdnsservers Wi-Fi 2>/dev/null | xargs)"
echo
echo "Send this to Satyam:  $(whoami)@${IP:-?}"
