# Phase 2 Evidence Index

Everything here was produced by the scripts in `scripts/phase2/` against the live 3-Mac system on **24 Nov 2026**
(client: Satyam's Mac `10.7.15.19`; edge1 + DNS #2: Krishna's Mac `10.7.15.23`; backends + edge2: Akshit's Mac `10.7.15.21`).
Each log contains the exact commands, their real output and PASS/FAIL checks. Re-run any of them with
`scripts/phase2/run-tests.sh <name>`.

## Logs (`logs/`)

| File | Covers | Key lines |
| --- | --- | --- |
| [p1.log](logs/p1.log) | Phase 1 regression: Task A inventory + ping matrix, B both resolvers + NXDOMAIN, C backends from the edge, D/E HTTPS by name (verified cert, TLS 1.3, h2), round robin, F `Cache-Control`/`ETag`/`304`, :80 → 301 | `SSL certificate verify ok`, `x-backend` A/B alternating, `HTTP/2 304` — 6/6 PASS |
| [p1fail.log](logs/p1fail.log) | Brief §6.3 failures: wrong DNS server, record → wrong IP, one backend down, both down, wrong port | F1 NXDOMAIN/timeout but TCP to the edge works; F2 exit 7; F3 4/4 via B; F4 `HTTP/2 502` with TLS still verifying; F5 exit 7 on :8443 |
| [extA.log](logs/extA.log) | Backup DNS: primary stopped, client resolves via Krishna's Mac; DNS failure vs application failure | `SERVER: 10.7.15.23`, `HTTPS while the primary is down: 200`, then `HTTP 502` with DNS working — 2/2 PASS |
| [extB.log](logs/extB.log) | TTL 30 s, record change on both resolvers, client keeps the cached answer, then switches | `t=+21s client=10.7.15.23 server=10.7.15.21` … `t=+26s client=10.7.15.21` — PASS |
| [extC.log](logs/extC.log) | pf isolation on Akshit's Mac: edge → backend 200, client → backend timeout (exit 28), via edge 200, rollback | run with `scripts/phase2/run-tests.sh extC` (asks Akshit's password) |
| [extD.log](logs/extD.log) | Backend A stopped: 8/8 served by B; nginx retry `upstream_status=502, 200`; A rejoins after 10 s | 2/2 PASS |
| [extE.log](logs/extE.log) | Standby edge + DNS cutover: fresh lookup (Mac 3) → edge2 at once; cached client on edge1 until +23 s, then edge2; edge1 stopped, service still up | 2/2 PASS |
| [extF-drills.log](logs/extF-drills.log) | 8 injected faults (wrong record, both DNS down, nginx down, wrong listen port, wrong upstream ports, wrong cert, both backends down, one backend down), each diagnosed by `scripts/diagnose.sh`; final check healthy | `>>> FIRST FAILING LAYER: …` per drill |

## Packet captures (`captures/`)

Open in Wireshark. Each `.txt` next to a capture is a tshark summary with frame numbers to point at.
Satyam's Mac is both the client and DNS #1, so its own DNS query crosses **lo0** — the captures record lo0 and en0
together (merged with `mergecap`).

| Capture | What to show |
| --- | --- |
| [phase2-full-flow-lan.pcapng](captures/phase2-full-flow-lan.pcapng) ([summary](captures/phase2-full-flow-lan.txt), [curl](captures/phase2-full-flow-lan.curl.txt)) | **DNS** frames 1–2: query from an ephemeral port to :53, answer `10.7.15.23` TTL 30. **TCP** SYN / SYN-ACK / ACK `10.7.15.19:<ephemeral> → 10.7.15.23:443` (seq/ack numbers listed). **TLS 1.2** ClientHello (SNI `app.teamx.test`), ServerHello + **Certificate** (SAN `app.teamX.test, api.teamX.test`), ServerKeyExchange, ChangeCipherSpec, then encrypted Application Data. Stream 1 is the same request over TLS 1.3 + HTTP/2 (certificate no longer visible). Filters: `dns`, `tcp.flags.syn==1`, `tls.handshake`, `tls.app_data`. |
| [extA-dns-failover.pcapng](captures/extA-dns-failover.pcapng) ([summary](captures/extA-dns-failover.txt)) | Primary stopped: query to `10.7.15.19` → **ICMP Port unreachable** (frame 2); ~1 s later the same query ID goes to `10.7.15.23`, which answers `10.7.15.23` (frames 3–4). |
| [extE-edge-cutover.pcapng](captures/extE-edge-cutover.pcapng) ([summary](captures/extE-edge-cutover.txt)) | Before: TCP/TLS to edge1 `10.7.15.23:443`. After the record change + TTL: DNS answer `10.7.15.21` (frames 37–38), then SYN + ClientHello to edge2 `10.7.15.21:443`. |
| `extC-isolation-client-side.pcapng` | create with `scripts/phase2/capture.sh isolation` while the firewall is applied: client SYNs to :3001 retransmitted, never answered. |

## Config snapshot

Rendered configs exactly as deployed: [`config/rendered/`](../../config/rendered) — dnsmasq for Mac 1 and Mac 2, nginx
(main + site) for edge1 and edge2, pf rules for Mac 3. Phase 1 originals: `nginx/phase1-cn-project.conf`, `dnsmasq/phase1-dnsmasq.conf`.
