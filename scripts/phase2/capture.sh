#!/bin/bash
# capture.sh - packet captures for the evidence folder. No sudo needed: the
# Wireshark installer puts us in the access_bpf group, so tcpdump can read en0.
# Run on Satyam's Mac (Mac 1).
#
#   scripts/phase2/capture.sh flow       Task G: DNS -> TCP -> TLS 1.2 -> HTTP across the LAN (+ a TLS 1.3/HTTP/2 request)
#   scripts/phase2/capture.sh failover   Ext A: primary DNS stopped -> ICMP port unreachable -> backup answers
#   scripts/phase2/capture.sh cutover    Ext E: DNS answer changes -> TCP/TLS now goes to the standby edge
#   scripts/phase2/capture.sh isolation  Ext C: client SYNs to :3001 get no answer (run while the firewall is ON)
#
# Output: evidence/phase_2/captures/<name>.pcapng + a tshark summary <name>.txt (frame numbers to point at)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"
OUT="$ROOT/evidence/phase_2/captures"; mkdir -p "$OUT"
TSHARK=/Applications/Wireshark.app/Contents/MacOS/tshark
[ -x "$TSHARK" ] || TSHARK="$(command -v tshark || true)"
[ -n "$TSHARK" ] || { echo "tshark not found - install Wireshark"; exit 1; }
Q='dns.qry.name matches "(?i)teamx\\.test"'
IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"; IF="${IF:-en0}"

start_cap() {  # start_cap <file-prefix> <bpf filter on the LAN interface> [bpf filter on lo0]
    # Satyam's Mac is the client AND DNS #1, so its own DNS queries travel over lo0:
    # capture lo0 too and merge, so the whole request is in one file.
    tcpdump -i "$IF" -s 0 -U -w "$1.lan.pcap" "$2" >/dev/null 2>&1 & CAP="$!"
    if [ -n "${3:-}" ]; then tcpdump -i lo0 -s 0 -U -w "$1.lo0.pcap" "$3" >/dev/null 2>&1 & CAP="$CAP $!"; fi
    sleep 1.5
    for p in $CAP; do kill -0 "$p" 2>/dev/null || { echo "tcpdump failed (are you in the access_bpf group? open Wireshark once)"; exit 1; }; done
}
stop_cap() {   # stop_cap <file-prefix>   (merges the per-interface files into <prefix>.pcapng)
    sleep 1; kill $CAP 2>/dev/null; wait $CAP 2>/dev/null
    "$(dirname "$TSHARK")/mergecap" -F pcapng -w "$1.pcapng" "$1".*.pcap 2>/dev/null && rm -f "$1".*.pcap
}
tsv() { "$TSHARK" -r "$1" -Y "$2" -T fields -E separator=' | ' "${@:3}" 2>/dev/null; }
wait_fresh() { echo "(waiting $((DNS_TTL + 2)) s so the client cache is empty and the client must really ask DNS)"; sleep $((DNS_TTL + 2)); }

case "${1:-}" in
flow)
    F="$OUT/phase2-full-flow-lan"
    sudo -n dscacheutil -flushcache 2>/dev/null && sudo -n killall -HUP mDNSResponder 2>/dev/null || wait_fresh
    start_cap "$F" "(udp port 53 and host $DNS2_IP) or (tcp port 443 and (host $EDGE1_IP or host $EDGE2_IP))" "udp port 53"
    # One real request: system resolver -> team DNS, then HTTPS. TLS 1.2 so the
    # Certificate message is visible in clear text (TLS 1.3 encrypts it).
    curl -sv --tlsv1.2 --tls-max 1.2 "https://$APP/api/status" > "$F.curl.txt" 2>&1
    curl -sv --http2 "https://$APP/api/status" >> "$F.curl.txt" 2>&1     # and a TLS 1.3 + HTTP/2 one
    stop_cap "$F"
    {
      echo "# ${F#$ROOT/}.pcapng  ($(date))  client $(ipconfig getifaddr "$IF") on $IF"
      echo "# Satyam's Mac is the client AND DNS #1, so its query to $DNS1_IP:53 crosses lo0 (src = dst = $DNS1_IP);"
      echo "# lo0 and $IF were captured together and merged. Another client's query would cross the LAN the same way."
      echo; echo "## DNS (filter: $Q)  frame | src | sport | dst | dport | query | answer | TTL"
      tsv "$F.pcapng" "$Q" -e frame.number -e ip.src -e udp.srcport -e ip.dst -e udp.dstport -e dns.qry.name -e dns.a -e dns.resp.ttl
      echo; echo "## TCP 3-way handshakes to the edge (SYN, SYN-ACK, ACK)  frame | stream | src | sport | dst | dport | flags | seq(raw) | ack(raw)"
      tsv "$F.pcapng" "tcp.flags.syn==1 or (tcp.flags.ack==1 and tcp.seq==1 and tcp.ack==1 and tcp.len==0)" -e frame.number -e tcp.stream -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.flags.str -e tcp.seq_raw -e tcp.ack_raw
      echo; echo "## TLS handshake (filter: tls.handshake or tls.change_cipher_spec)  frame | stream | src | dst | info | SNI"
      tsv "$F.pcapng" "tls.handshake or tls.change_cipher_spec" -e frame.number -e tcp.stream -e ip.src -e ip.dst -e _ws.col.Info -e tls.handshake.extensions_server_name
      echo; echo "## Certificate sent by the server in TLS 1.2 (filter: tls.handshake.type==11)  frame | SAN"
      tsv "$F.pcapng" 'tls.handshake.type==11' -e frame.number -e x509ce.dNSName | head -2
      echo; echo "## Encrypted application data (filter: tls.app_data), first 6  frame | stream | src | dst | length"
      tsv "$F.pcapng" "tls.app_data" -e frame.number -e tcp.stream -e ip.src -e ip.dst -e frame.len | head -6
      echo; echo "## curl view of the same requests"
      grep -E 'Connected to|SSL connection|ALPN|subject:|issuer:|SSL certificate verify|^< HTTP|^< x-' "$F.curl.txt"
    } > "$F.txt"
    cat "$F.txt" ;;
failover)
    F="$OUT/extA-dns-failover"
    wait_fresh
    start_cap "$F" "port 53 or icmp" "port 53 or icmp"
    run_on mac1 "$CN dns stop"
    dig "$APP" +time=2 +nocmd +noall +answer +stats | grep -E 'IN|SERVER'
    dscacheutil -q host -a name "$APP" | grep ip_address
    run_on mac1 "$CN dns start"
    stop_cap "$F"
    { echo "# ${F#$ROOT/}.pcapng  ($(date)) - primary DNS ($DNS1_IP) stopped, backup ($DNS2_IP) answers"
      echo "frame | time | src | dst | proto | info"
      tsv "$F.pcapng" "($Q) or icmp" -e frame.number -e frame.time_relative -e ip.src -e ip.dst -e _ws.col.Protocol -e _ws.col.Info; } > "$F.txt"
    cat "$F.txt" ;;
cutover)
    F="$OUT/extE-edge-cutover"
    wait_fresh
    start_cap "$F" "(udp port 53 and host $DNS2_IP) or (tcp port 443 and (host $EDGE1_IP or host $EDGE2_IP))" "udp port 53"
    curl -s -o /dev/null -D - "https://$APP/api/status" | grep -i x-edge
    run_on mac1 "$CN dns-record $EDGE2_IP" >/dev/null; run_on mac2 "$CN dns-record $EDGE2_IP" >/dev/null
    sleep $((DNS_TTL + 2))
    curl -s -o /dev/null -D - "https://$APP/api/status" | grep -i x-edge
    stop_cap "$F"
    run_on mac1 "$CN dns-record $EDGE1_IP" >/dev/null; run_on mac2 "$CN dns-record $EDGE1_IP" >/dev/null
    { echo "# ${F#$ROOT/}.pcapng  ($(date)) - before: answer $EDGE1_IP -> TLS to edge1; after cutover: answer $EDGE2_IP -> TLS to edge2"
      echo "frame | time | src | dst | info"
      tsv "$F.pcapng" "($Q) or tcp.flags.syn==1 or tls.handshake.type==1" -e frame.number -e frame.time_relative -e ip.src -e ip.dst -e _ws.col.Info; } > "$F.txt"
    cat "$F.txt" ;;
isolation)
    F="$OUT/extC-isolation-client-side"
    start_cap "$F" "tcp port 3001 or tcp port 3002"
    curl -s -m 4 -o /dev/null "http://$BACKEND_A/api/status"; echo "client -> A exit=$? (28 = timeout: dropped by pf)"
    stop_cap "$F"
    { echo "# ${F#$ROOT/}.pcapng  ($(date)) - client SYNs to $BACKEND_A retransmitted, never answered"
      echo "frame | time | src | sport | dst | dport | flags"
      tsv "$F.pcapng" tcp -e frame.number -e frame.time_relative -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.flags.str | head -20; } > "$F.txt"
    cat "$F.txt" ;;
*) sed -n '2,12p' "$0"; exit 2 ;;
esac
