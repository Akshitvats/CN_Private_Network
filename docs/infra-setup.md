# Infrastructure Setup — from zero to a working 3-Mac network

Use this when setting the project up on fresh Macs, after a reinstall, or when something was removed.
For the normal start of a session (everything already installed) use the [runbook](phase2-runbook.md#1-start-of-every-session-2-minutes).

Everything is driven from **Satyam's Mac (Mac 1, the operator)**. Run commands from the `CN_Private_Network/` folder.

## 0. What runs where

| Mac | User | Software needed | Services (all under `~/cn-project/`) |
| --- | --- | --- | --- |
| Mac 1 — Satyam | `satyamkumar` | dnsmasq, Wireshark (tshark, mergecap, tcpdump access) | dnsmasq :53 primary · test client · operator |
| Mac 2 — Krishna | `krishnaverma` | nginx, dnsmasq, mkcert (owns the team CA) | nginx edge1 :80/:443 (**as root**) · dnsmasq :53 backup |
| Mac 3 — Akshit | `akshitvats` | nginx, Xcode Command Line Tools (`/usr/bin/python3`) | Flask A :3001, B :3002 · nginx edge2 :80/:443 · pf rules |

Nothing is started by `brew services`; `cn.sh` starts every service from `~/cn-project` as the normal user (except edge1, see step 7).

## 1. Every Mac: network + remote login

1. Join the **same Wi-Fi** (college LAN, currently 10.7.0.0/19).
2. Krishna and Akshit: **System Settings → General → Sharing → Remote Login: ON** (allow their own user).
3. Each Mac: `scripts/get-my-ip.sh` (or `ipconfig getifaddr en0`) and send the IP to Satyam.
4. From Mac 1: `ping -c 2 <ip>` for each teammate.

## 2. Software (Homebrew)

```bash
# Mac 1 (Satyam)
brew install dnsmasq
brew install --cask wireshark        # then open Wireshark once and allow ChmodBPF -> capture without sudo
groups | grep -q access_bpf && echo "can capture without sudo"

# Mac 2 (Krishna)
brew install nginx dnsmasq mkcert
mkcert -install                      # creates Krishna's local CA (only once, ever)

# Mac 3 (Akshit)
brew install nginx
xcode-select --install               # only if /usr/bin/python3 is missing (Flask goes into a venv later)
```

The installs on Mac 2 and Mac 3 can also be run from Mac 1, since Homebrew needs no sudo:
`ssh krishnaverma@<ip> '/opt/homebrew/bin/brew install nginx dnsmasq mkcert'`.

## 3. Passwordless SSH from Mac 1

```bash
ls ~/.ssh/id_ed25519 || ssh-keygen -t ed25519                  # once on Mac 1
ssh-copy-id -i ~/.ssh/id_ed25519.pub krishnaverma@<Krishna IP>   # asks Krishna's password once
ssh-copy-id -i ~/.ssh/id_ed25519.pub akshitvats@<Akshit IP>      # asks Akshit's password once
ssh -o BatchMode=yes krishnaverma@<Krishna IP> hostname          # must print the hostname, no prompt
ssh -o BatchMode=yes akshitvats@<Akshit IP> hostname
```

## 4. Inventory (`team/team.env`)

```bash
scripts/update-ips.sh mac2=<Krishna IP> mac3=<Akshit IP>
```

It detects Mac 1's own IP, confirms each teammate's IP over SSH, rewrites the `MACn_IP` lines and re-renders
`config/rendered/`. If a teammate's **username** differs, edit `MACn_USER` in `team/team.env` first.

## 5. TLS: team CA and edge certificate

- The CA lives on Krishna's Mac (`mkcert -CAROOT`). Its **public** certificate is committed as `tls/mkcert-rootCA.pem`.
- If the CA is new (fresh Mac 2), refresh the repo copy:
  ```bash
  scp krishnaverma@<Krishna IP>:'Library/Application\ Support/mkcert/rootCA.pem' tls/mkcert-rootCA.pem
  ```
- The edge certificate is created or reused by `deploy.sh` (next step). Use `scripts/deploy.sh --tls` to force a
  new one, e.g. after a new CA or before expiry (current cert: 4 Jan 2029). The same cert and key go to both edges.

## 6. First deploy

```bash
scripts/deploy.sh
```

It checks SSH to each Mac, renders configs, copies `~/cn-project/` to every Mac, creates the Flask venv on Mac 3
(`pip install flask`, needs Internet the first time), installs the certificate on both edges, starts backends → DNS
→ edges, and prints the status. If it stops at edge1 with *"edge1 needs root mode"*, do step 7 and run it again.

## 7. One-time admin steps (each needs that Mac's password, in your own terminal)

| # | Where | Command | Why |
| --- | --- | --- | --- |
| a | Mac 2 | `ssh -t krishnaverma@<ip> 'sudo /opt/homebrew/bin/brew services stop nginx'` | only if an old root nginx (Phase 1) holds :80/:443 |
| b | Mac 1 | `sudo brew services stop dnsmasq` | only if an old root dnsmasq holds :53 |
| c | Mac 2 | `ssh -t krishnaverma@<ip> 'sudo ~/cn-project/bin/edge-root.sh install'` | edge1 must run as root (macOS Local Network privacy, [why](architecture.md#why-edge1-runs-as-root-macos-local-network-privacy)) |
| d | each client | `sudo scripts/phase2/client-setup.sh` on Mac 1; `sudo ~/cn-project/bin/client-setup.sh` on others | Wi-Fi DNS = DNS #1 + DNS #2, trust the team CA, remove the Phase 1 `/etc/resolver` file |

After **c**: `scripts/deploy.sh` (or `ssh krishnaverma@<ip> '~/cn-project/bin/cn.sh edge restart'`).
Repeat **d** on a client whenever the DNS server IPs change.

## 8. Verify

```bash
scripts/deploy.sh status                 # every service UP; edge1 "master runs as root"
scripts/smoke-test.sh                    # RESULT: 7 passed, 0 failed
scripts/demo.sh check                    # >>> All layers healthy.
scripts/phase2/run-tests.sh all          # full evidence run (~5 min)
sudo -v && scripts/phase2/run-tests.sh extB    # with the manual cache flush
scripts/phase2/run-tests.sh extC         # pf firewall (Akshit's password x3)
```

## 9. Common setup errors

| Symptom | Cause | Fix |
| --- | --- | --- |
| `deploy.sh` preflight `FAIL … unreachable` | IP changed / Remote Login off / key not authorized | step 1, `update-ips.sh`, step 3 |
| `Permission denied (publickey…)` | Mac 1's key not on that Mac | `ssh-copy-id` (step 3) |
| `bind() to 0.0.0.0:443 failed (48: Address already in use)` | another nginx (often root, from `sudo brew services`) | step 7a |
| `dnsmasq FAILED … Address already in use` | root dnsmasq from brew services | step 7b |
| 502 + nginx log `connect() … (65: No route to host)` | edge1 running as a normal user (Local Network privacy) | step 7c, then `cn.sh edge restart` |
| `root edge mode is not installed on this Mac` | step 7c not done | step 7c |
| `backend venv missing` | first deploy without Internet | connect, `scripts/deploy.sh` |
| `system resolver cannot resolve app.teamX.test` | client not using team DNS / old `/etc/resolver/teamX.test` | step 7d |
| curl error 60 / `SSL certificate problem` | client does not trust the team CA, or the CA changed | step 5 + step 7d |
| `tcpdump failed` in `capture.sh` | not in `access_bpf` | open Wireshark once (ChmodBPF) |

## 10. Shut down / undo everything

```bash
scripts/deploy.sh stop                                                   # stop all project services
sudo scripts/phase2/client-setup.sh --undo                               # Mac 1 DNS back to before
ssh -t krishnaverma@<ip> 'sudo ~/cn-project/bin/edge-root.sh uninstall'  # remove root helper + sudoers rule
ssh -t akshitvats@<ip> 'sudo ~/cn-project/bin/firewall.sh rollback'      # only if pf was left on
# optional: rm -rf ~/cn-project on each Mac; brew uninstall dnsmasq (Mac 2) / nginx (Mac 3)
```
