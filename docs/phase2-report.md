# Phase 2 Final Report — Harden, Recover, and Troubleshoot

**Team:** Satyam Kumar (2401010428, Mac 1) · Krishna Verma (2401010240, Mac 2) · Akshit Vats (2401020085, Mac 3)
**Tested:** 24 Nov 2026 on the college Wi-Fi (10.7.0.0/19). Every result below comes from a log in
[`evidence/phase_2/logs/`](../evidence/phase_2/logs) produced by `scripts/phase2/run-tests.sh` / `fault-drills.sh`.

## 1. Starting point: the Phase 1 system one month later

Coming back to the Phase 1 setup, nothing worked by name. That turned out to be a useful exercise in its own right:

| Symptom | Layer | Cause | Fix |
| --- | --- | --- | --- |
| Every Mac had a new address (`10.7.10.50 → .15.19`, `.15.125 → .15.23`, `.12.174 → .15.21`) | L3 | DHCP leases changed | single inventory `team/team.env` + `update-ips.sh` (verifies each Mac over SSH) |
| `https://app.teamX.test` → **502**, no `X-Edge` header | L7 | the **Phase 1 root nginx** (started with `sudo brew services` on 13 Nov) was still running on Krishna's Mac, proxying to the old backend IP `10.7.12.174`, and holding :80/:443 | stopped it once; nginx now runs from `~/cn-project` under `cn.sh` |
| New nginx on Krishna's Mac → 502, error log `connect() to 10.7.15.21:3001 failed (65: No route to host)` while `curl` from the same Mac worked | L3 as seen by one process | **macOS Local Network privacy**: a non-Apple daemon started over SSH loses LAN access when the SSH session ends; root is exempt | edge1 runs as root through a root-owned helper (`edge-root.sh`) |
| My Mac resolved `*.teamX.test` only via `/etc/resolver/teamX.test → 127.0.0.1` | L2 | Phase 1 per-domain resolver — bypasses any backup DNS | `client-setup.sh`: Wi-Fi DNS = DNS #1 + DNS #2 |

The Local Network finding took the longest. We isolated it by running the same Homebrew binary (`openssl s_client`) three
ways on Krishna's Mac: in the foreground of an SSH session → `CONNECTED`; detached but while the session was still open →
`CONNECTED`; detached after the session closed → `No route to host`. The same experiment under a launchd job also
failed. Apple's own `curl` was never affected. Phase 1 had never hit this because nginx ran as root.

## 2. What changed from Phase 1

| Area | Phase 1 | Phase 2 |
| --- | --- | --- |
| Configuration | edited by hand on each Mac, IPs hard-coded | `team/team.env` → `render-configs.sh` → `deploy.sh` pushes a self-contained `~/cn-project` to every Mac over SSH |
| DNS | one dnsmasq on Mac 1 (`host-record`, root) | primary (Mac 1) + **backup** (Mac 2) with an identical zone in a hosts file reloaded by SIGHUP; `local-ttl=30`; `local=/teamX.test/` |
| Clients | `/etc/resolver/teamX.test` → 127.0.0.1 | Wi-Fi DNS lists both resolvers; non-project names forwarded upstream |
| Edge | round robin, `max_fails=2`, :80 served plain HTTP | `max_fails=1 fail_timeout=10s` + `proxy_next_upstream` retry, 2 s connect timeout; :80 → 301 HTTPS; `X-Edge` header; `/edge-health`; access log with `upstream=` / `upstream_status=` |
| Standby | — | edge2 on Mac 3, same config and same certificate + key |
| Isolation | backends open to the whole Wi-Fi | pf anchor on Mac 3: only edge1 may reach 3001/3002; rollback copy of the original pf state |
| Operations | manual commands | `cn.sh` (per Mac), `demo.sh` (guided demo), `diagnose.sh` (layer-by-layer), `run-tests.sh` / `fault-drills.sh` / `capture.sh` (evidence) |
| Installed | — | dnsmasq on Mac 2, nginx on Mac 3, Flask venv in `~/cn-project/backend` on Mac 3 |

## 3. Resilience tests and results

| Test (log) | What we did | Observed | Result |
| --- | --- | --- | --- |
| Phase 1 regression ([p1](../evidence/phase_2/logs/p1.log)) | ping matrix, both resolvers, HTTPS, LB, caching | `SSL certificate verify ok`, TLS 1.3 + h2, A/B alternating 8/8, `304`, `:80 → 301` | 6/6 PASS |
| Phase 1 failures ([p1fail](../evidence/phase_2/logs/p1fail.log)) | wrong DNS server, wrong record IP, 1 and 2 backends down, wrong port | NXDOMAIN / timeout but TCP to the edge works; exit 7 refused; B serves 4/4; **502** with TLS still verifying; exit 7 on :8443 | PASS |
| Ext A backup DNS ([extA](../evidence/phase_2/logs/extA.log)) | stop dnsmasq on Mac 1 | `dig` SERVER switches to `10.7.15.23`; HTTPS 200; Krishna's dnsmasq log shows our queries; with backends stopped → name resolves but **502** | 2/2 PASS |
| Ext B TTL ([extB](../evidence/phase_2/logs/extB.log)) | record → `10.7.15.21` on both resolvers | server changes at once; client keeps `10.7.15.23` for **~25 s**, then switches; record back → client switches after ~40 s (or instantly after a flush) | PASS |
| Ext C isolation ([extC](../evidence/phase_2/logs/extC.log)) | pf on Mac 3 | expected: client → :3001 timeout (exit 28); edge → 200; via edge 200; rollback restores direct access | **pending** — needs Akshit's sudo password: `scripts/phase2/run-tests.sh extC` |
| Ext D HA failover ([extD](../evidence/phase_2/logs/extD.log)) | stop Backend A | **8/8 × 200 from B**; nginx access log `upstream_status=502, 200` (retried on B), error log `Connection refused` + `temporarily disabled`; A back in rotation after 10 s | 2/2 PASS |
| Ext E edge cutover ([extE](../evidence/phase_2/logs/extE.log)) | record → edge2 | fresh lookup (Mac 3) → `edge2-mac3` immediately; cached client on `edge1-mac2` until **t=+23 s**, then `edge2-mac3`; edge1 stopped → still 200 | 2/2 PASS |
| Ext F drills ([extF-drills](../evidence/phase_2/logs/extF-drills.log)) | 8 injected faults | each one named at the right layer (table below); final check healthy | 8/8 |

## 4. Troubleshooting findings (Extension F)

`scripts/diagnose.sh` checks bottom-up and stops at the first failure: L1 client network → L2 DNS (each resolver and
the system resolver) → L3 ping → L4 `nc -z` (refused = fast, filtered = slow) → L5 `openssl s_client -verify_hostname`
against the team CA → L6 HTTP status + `X-Edge` → L7 `X-Backend` across 6 requests.

| Drill | Injected fault | diagnose.sh verdict |
| --- | --- | --- |
| 1 | record → Satyam's Mac (no web server) | L2 DNS (wrong record), seen at L4: resolves to a non-edge, refused |
| 2 | both resolvers stopped | L2 DNS (servers) |
| 3 | nginx stopped on edge1 | L4 TCP refused |
| 4 | nginx moved to :8443 | L4 TCP refused (host up, nothing on :443) |
| 5 | upstream ports changed to :3011/:3012 | L7 edge → backend (502); `DEEP=1` prints the wrong upstream lines |
| 6 | self-signed cert for `wrong.test` | L5 TLS (`self-signed certificate`, name mismatch) |
| 7 | both backends stopped | L7 edge → backend (502) |
| 8 | Backend A stopped | all layers pass, **WARN** only one backend in rotation (failover hides it) |

Real faults found the same way during this phase are in section 1. One more came from a drill: drill 8 first reported
502 because it started right after drill 7. nginx was still inside the 10 s `fail_timeout` for Backend B, so for a
moment **no** upstream was eligible. Passive health checks have a memory, and the drill script now waits it out.

## 5. Learning summary (one paragraph per extension)

**A — Backup DNS.** Redundancy in DNS lives in the client's resolver list, not in the server: both dnsmasq instances
serve an identical zone, and the macOS resolver moves on when the primary does not answer. Stopping the primary only
cost us the queries cached on it. Failing a resolver is a different class of failure from failing the application.
Without DNS nothing even starts, while with DNS up and backends down TCP and TLS succeed and the edge answers 502.

**B — TTL.** The TTL is a promise the server makes to every cache. Once handed out, an answer cannot be recalled. Our
client kept the old address for about 25 s after the change, which is why migrations start by lowering the TTL and
why the old server must keep running for one TTL afterwards. A manual flush shows the change at once, but you can
only flush your own machine, never your users'.

**C — Service isolation.** With pf allowing only the edge, the backends disappear for everyone else. A client SYN is
silently dropped, so the client sees a timeout (curl exit 28), whereas a stopped service answers RST and fails
instantly (exit 7). That difference is how you tell "filtered" from "closed". We load rules into a `com.apple/` anchor
so no system file changes, and keep a rollback copy as the brief requires. This is the security-group idea of
"backend port open only to the load balancer".

**D — High availability.** nginx's passive health checks plus `proxy_next_upstream` made a dead backend invisible.
The failed attempt is retried on B inside the same client request (`upstream_status=502, 200`), and A is skipped
for 10 s, then probed again. The edge itself is still a single point of failure. Removing it needs a second edge
with a floating IP (VRRP/keepalived) or a managed load balancer.

**E — DNS cutover.** Moving users to the standby edge needed only a record change, because both edges present the
same certificate and TLS checks the name, not the IP. The cutover is not instant. New lookups move immediately,
while cached clients follow within one TTL, so both edges must serve during that window. That is the core of
blue-green deployments behind DNS.

**F — Troubleshooting.** Checking layers in order and stopping at the first failure beats guessing. The same symptom
(the site does not load) came from eight different causes, and each one shows up at a distinct layer with its own
signature: NXDOMAIN or no answer, refused versus timeout, certificate errors, 502. The most instructive faults were
the ones we did not inject: a stale root nginx, and a macOS privacy feature that made one process see "no route"
on a network every other process could use.

## 6. Remaining single points of failure

1. **Edge1** — fix with VRRP/keepalived floating IP or a health-checked managed LB; Ext E is our manual stand-in.
2. **Both backends on one Mac** — move Backend B to a fourth machine.
3. **The shared Wi-Fi** — one access point carries every hop.
4. **The CA key on Krishna's Mac** — back it up; without it no new certificates can be issued.
