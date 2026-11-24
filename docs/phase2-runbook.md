# Phase 2 Runbook — Setup, Final Demo, Rollback

Everything is driven from **Satyam's Mac (Mac 1)**, which has passwordless SSH to Krishna's and Akshit's Macs.
Setting up from scratch (new Macs, nothing installed)? Follow [infra-setup.md](infra-setup.md) first.
Run all commands from the project folder `CN_Private_Network/`.

## 0. Who is who

| Name to say | Mac | Today's IP | Runs |
| --- | --- | --- | --- |
| **Satyam's Mac** | Mac 1 | `10.7.15.19` | DNS #1 (primary), test client, operator |
| **Krishna's Mac** | Mac 2 | `10.7.15.23` | Front door = nginx edge1 · DNS #2 (backup) |
| **Akshit's Mac** | Mac 3 | `10.7.15.21` | Backend A :3001 · Backend B :3002 · spare front door edge2 · firewall |

## 1. Start of every session (2 minutes)

```bash
scripts/get-my-ip.sh                         # on EACH Mac - teammates send you their IP
scripts/update-ips.sh mac2=<Krishna> mac3=<Akshit> --deploy
#   checks each Mac over SSH, rewrites team/team.env, re-renders configs, deploys + starts everything
scripts/smoke-test.sh                        # expect: RESULT 7 passed, 0 failed
scripts/demo.sh check                        # expect: ">>> All layers healthy."
```

If the IPs did not change, `scripts/deploy.sh` alone is enough. `scripts/deploy.sh status` shows every service.

**If the DNS server IPs changed**, every client that ran `client-setup.sh` must run it again
(it writes the resolver IPs into Wi-Fi settings): `sudo scripts/phase2/client-setup.sh`.

## 2. One-time admin steps (need passwords — already done on 24 Nov 2026)

| Where | Command | Why |
| --- | --- | --- |
| Krishna's Mac | `ssh -t krishnaverma@<ip> 'sudo /opt/homebrew/bin/brew services stop nginx'` | stop the Phase 1 root nginx that held :80/:443 |
| Krishna's Mac | `ssh -t krishnaverma@<ip> 'sudo ~/cn-project/bin/edge-root.sh install'` | edge1 runs as root (macOS Local Network privacy, see [architecture](architecture.md#why-edge1-runs-as-root-macos-local-network-privacy)) |
| Each client Mac | `sudo scripts/phase2/client-setup.sh` (repo) or `sudo ~/cn-project/bin/client-setup.sh` | DNS = DNS #1 + DNS #2, trust the team CA, remove the Phase 1 `/etc/resolver/teamX.test` |
| Akshit's Mac | (during Ext C) `sudo ~/cn-project/bin/firewall.sh apply / rollback` | pf needs root — `demo.sh C` asks Akshit's password over SSH |

Software installed by us: `dnsmasq` on Krishna's Mac, `nginx` on Akshit's Mac (Homebrew), Flask in `~/cn-project/backend/.venv` on Akshit's Mac.

## 3. Final demonstration sequence (brief §8)

| # | Step | Command (Satyam's Mac) | Who explains |
| --- | --- | --- | --- |
| 1 | Topology + IP/service inventory | open [architecture.md](architecture.md); `scripts/demo.sh who` | Satyam |
| 2 | All Macs on the LAN | `scripts/demo.sh p1` (step 2 part) — `ping`, `ipconfig getifaddr en0` | Satyam |
| 3 | Resolve the private name | `dig app.teamX.test` → `10.7.15.23`, SERVER `10.7.15.19` | Satyam |
| 4 | HTTPS by name, no warnings | `curl -v https://app.teamX.test/api/status` (no `-k`), or the browser | Krishna |
| 5 | Load balancing | `for i in 1 2 3 4 5 6; do curl -sI https://app.teamX.test/api/status \| grep -i x-backend; done` | Krishna |
| 6 | Wireshark evidence | open `evidence/phase_2/captures/phase2-full-flow-lan.pcapng` (+ the `.txt` frame index) | Satyam |
| 7 | Headers + caching | `curl -I https://app.teamX.test/api/cache`; `curl -i -H 'If-None-Match: "cn-cache-v1"' …` → 304 | Akshit |
| 8 | Fail one backend | `scripts/demo.sh D` | Krishna / Akshit |
| 9 | Phase 2 DNS + resilience | `scripts/demo.sh A`, `scripts/demo.sh B`, `scripts/demo.sh E`, `scripts/demo.sh C` | Satyam (A, B), Akshit (C), Krishna (E) |
| 10 | Faculty-injected fault | `scripts/demo.sh F` (= `scripts/diagnose.sh`), then fix the layer it names | everyone |
| 11 | Viva | [viva-prep.md](viva-prep.md) | everyone |

`scripts/demo.sh p1` runs steps 2–8 in one guided sequence. Every `demo.sh` section pauses for Enter between
parts and prints **SAY:** / **LOOK AT:** hints. `NOPAUSE=1 scripts/demo.sh X` runs without pauses.

## 4. Extension commands in detail

### A — Backup DNS
```bash
dig @10.7.15.19 app.teamX.test +short; dig @10.7.15.23 app.teamX.test +short   # same answer
~/cn-project/bin/cn.sh dns stop          # on Satyam's Mac: stop DNS #1
sleep 32; dig app.teamX.test            # SERVER: 10.7.15.23 - the backup answered
curl -sI https://app.teamX.test/api/status   # still HTTP/2 200
~/cn-project/bin/cn.sh dns start
```

### B — TTL and controlled record change
```bash
dig @10.7.15.19 app.teamX.test +noall +answer          # TTL 30
# change the record on BOTH resolvers:
~/cn-project/bin/cn.sh dns-record 10.7.15.21
ssh krishnaverma@10.7.15.23 '~/cn-project/bin/cn.sh dns-record 10.7.15.21'
dscacheutil -q host -a name app.teamX.test             # OLD for up to 30 s, then NEW
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder   # flush = immediate
```

### C — Service isolation (pf on Akshit's Mac)
```bash
ssh -t akshitvats@10.7.15.21 'sudo ~/cn-project/bin/firewall.sh apply'
curl -m 4 http://10.7.15.21:3001/api/status; echo $?                    # 28 = timeout (dropped)
ssh krishnaverma@10.7.15.23 'curl -s http://10.7.15.21:3001/api/status'  # edge: 200
ssh -t akshitvats@10.7.15.21 'sudo ~/cn-project/bin/firewall.sh rollback'
```

### D — HA failover
`scripts/demo.sh D` — stops Backend A, shows 6/6 requests served by B, shows nginx's `upstream_status=502, 200`
retry in the access log, restarts A and shows A rejoining after `fail_timeout` (10 s).

### E — DNS-based edge cutover
`scripts/demo.sh E` — record → `10.7.15.21`; a fresh lookup (Akshit's Mac) reaches edge2 at once; Satyam's Mac
(cached) stays on edge1 until its 30 s TTL expires; edge1 can then be stopped; then everything is rolled back.

### F — Troubleshooting
```bash
scripts/diagnose.sh            # L1 network → L2 DNS → L3 IP → L4 TCP → L5 TLS → L6 HTTP → L7 backends
DEEP=1 scripts/diagnose.sh     # + checks the edge→backend hop on the edge itself
scripts/demo.sh break          # practice: random hidden fault   (break <name> for a specific one)
scripts/demo.sh answer         # reveal it
scripts/demo.sh fix            # repair everything
```

## 5. Evidence

```bash
scripts/phase2/run-tests.sh all       # p1 p1fail extA extB extD extE -> evidence/phase_2/logs/*.log
scripts/phase2/run-tests.sh extC      # needs Akshit's password (pf)
scripts/phase2/fault-drills.sh        # 8 injected faults + diagnose -> extF-drills.log
scripts/phase2/capture.sh flow        # Wireshark: DNS -> TCP -> TLS -> HTTP
scripts/phase2/capture.sh failover    # Wireshark: Ext A
scripts/phase2/capture.sh cutover     # Wireshark: Ext E
```

## 6. Rollback / end of session

```bash
scripts/demo.sh fix                                     # back to the normal state
scripts/deploy.sh stop                                  # stop every project service on every Mac
sudo scripts/phase2/client-setup.sh --undo              # this Mac's DNS back to what it was
ssh -t akshitvats@10.7.15.21 'sudo ~/cn-project/bin/firewall.sh rollback'          # if pf is still on
ssh -t krishnaverma@10.7.15.23 'sudo ~/cn-project/bin/edge-root.sh uninstall'      # remove root edge mode
```
