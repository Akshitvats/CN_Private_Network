# Video Demo: Wireshark Capture + curl Walkthrough

A script to record the private network working end to end, with packet proof captured in Wireshark.

| Mac | Role | IP (re-check before recording) |
| --- | --- | --- |
| **Mac 1** | DNS (dnsmasq) + **client + Wireshark** | `10.7.10.50` |
| **Mac 2** | nginx edge (TLS, HTTP/2, load balancer) | `10.7.15.125` |
| **Mac 3** | Backend A `:3001`, Backend B `:3002` | `10.7.12.174` |

Domain: `app.teamX.test`. Record on **Mac 1**. Mac 2 and Mac 3 only appear briefly to show configs and for the failover step.

---

## 0. Pre-flight (do this before you hit record)

IPs on college Wi-Fi can change, so check all three first.

```bash
# On EACH Mac
ipconfig getifaddr en0
```
If an IP changed:
- **Mac 3's IP changed:** update `/opt/homebrew/etc/nginx/servers/cn-project.conf` on Mac 2, then run `sudo nginx -t && sudo brew services restart nginx`.
- **Mac 2's IP changed:** update the `host-record` lines in `/opt/homebrew/etc/dnsmasq.conf` on Mac 1, then run `sudo brew services restart dnsmasq`.

Check that the services are up:
```bash
# Mac 3: two terminals
./scripts/run-backend.sh A
./scripts/run-backend.sh B

# Mac 1: quick health check
dig @10.7.10.50 app.teamX.test +short          # 10.7.15.125
curl -s https://app.teamX.test/api/status       # {"backend":"A"...}
```

Prepare the screen on Mac 1:
- One terminal with a big font (`Cmd +`).
- Wireshark open.
- Close noisy apps (browsers, chat, cloud sync) so the capture stays clean.

> The college Wi-Fi is sometimes slow. If a command hangs, press `Ctrl+C` and run it again.

---

## 1. Show the setup (≈1 min)

Show each config briefly, so the video proves the three roles live on three machines.

**Mac 1: DNS**
```bash
ipconfig getifaddr en0
tail -n 16 /opt/homebrew/etc/dnsmasq.conf
sudo brew services list | grep dnsmasq
```
*Point out:* `host-record=app.teamX.test,10.7.15.125,30` (name, then Mac 2's IP, then a 30s TTL), plus `listen-address` and `server=8.8.8.8`.

**Mac 2: nginx**
```bash
ipconfig getifaddr en0
cat /opt/homebrew/etc/nginx/servers/cn-project.conf
sudo nginx -t
```
*Point out:* the `upstream backend_pool` with two backends on Mac 3, `listen 443 ssl`, `http2 on`, the certificate paths and `ssl_protocols TLSv1.2 TLSv1.3`.

**Mac 3: backends**
```bash
ipconfig getifaddr en0
lsof -nP -iTCP:3001 -iTCP:3002 -sTCP:LISTEN
```
*Point out:* the same `backend/app.py` running twice (A on 3001, B on 3002), both bound to `*` (`0.0.0.0`).

---

## 2. Start the Wireshark capture (Mac 1)

1. **Flush the DNS cache** so a fresh DNS query appears in the capture:
   ```bash
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
   ```
2. In Wireshark, **select two interfaces** by holding `Cmd` and clicking:
   - **`Wi-Fi: en0`**: carries the TLS and HTTP traffic between Mac 1 and Mac 2.
   - **`Loopback: lo0`**: carries the DNS traffic. Mac 1 asks its *own* dnsmasq, and macOS sends traffic to its own IP through loopback.
3. Click the blue **shark fin** to start capturing.

---

## 3. Run the demo commands (Mac 1 terminal)

Run them in this order, pausing a moment between each one.

### 3.1 Private DNS
```bash
dig @10.7.10.50 app.teamX.test
```
*Say:* "Our private DNS answers `app.teamX.test` with `10.7.15.125`, which is the nginx Mac, with a 30-second TTL."

```bash
dig @8.8.8.8 app.teamX.test
```
*Say:* "Public DNS returns `NXDOMAIN`. The name only exists inside our private network."

### 3.2 Plain HTTP (unencrypted, to compare with TLS later)
```bash
curl -i http://app.teamX.test/api/status
```

### 3.3 Trusted HTTPS: TLS 1.3 + HTTP/2, no `-k`
```bash
curl -v https://app.teamX.test/api/status
```
*Point out in the output:*
- `SSL connection using TLSv1.3`
- `ALPN: server accepted h2`
- `issuer: mkcert development CA`
- `SSL certificate verify ok.`
- `HTTP/2 200`

### 3.4 Force TLS 1.2 (gives the clearest handshake in Wireshark)
```bash
curl --tlsv1.2 --tls-max 1.2 -sv -o /dev/null https://app.teamX.test/api/status 2>&1 | grep -E 'SSL connection|verify|HTTP/'
```
TLS 1.3 encrypts the server's certificate. With TLS 1.2, the **Certificate** message is readable in Wireshark.

### 3.5 HTTP/1.1 vs HTTP/2
```bash
curl --http1.1 -sI https://app.teamX.test/api/status | head -1
curl --http2   -sI https://app.teamX.test/api/status | head -1
```

### 3.6 Round-robin load balancing
```bash
for i in 1 2 3 4 5 6; do curl -s https://app.teamX.test/api/status; echo; done
```
*Say:* "nginx alternates between backend A and backend B."

Or show just the response header:
```bash
for i in 1 2 3 4 5 6; do curl -sI https://app.teamX.test/api/status | grep -i x-backend; done
```

### 3.7 Caching and conditional requests
```bash
curl -sI https://app.teamX.test/api/cache | grep -iE 'HTTP/|etag|cache-control|x-backend'
curl -si -H 'If-None-Match: "cn-cache-v1"' https://app.teamX.test/api/cache | head -1
```
*Say:* "The first response sends `ETag` and `Cache-Control: public, max-age=60`. When we send that ETag back, the server answers **304 Not Modified** with no body."

### 3.8 Failover
1. **On Mac 3**, stop Backend A with **`Ctrl+C`** in its terminal (show this on camera).
2. **On Mac 1**:
   ```bash
   curl -s -m 3 http://10.7.12.174:3001/api/status || echo "Backend A is DOWN"
   for i in 1 2 3 4 5 6; do curl -sI https://app.teamX.test/api/status | grep -i x-backend; done
   ```
   *Say:* "Backend A is down, so nginx (`max_fails=2 fail_timeout=10s`) sends every request to B. The client sees no errors."
3. **On Mac 3**, restart A: `./scripts/run-backend.sh A`.
4. Wait about 10 seconds, then on **Mac 1**:
   ```bash
   for i in 1 2 3 4 5 6; do curl -sI https://app.teamX.test/api/status | grep -i x-backend; done
   ```
   *Say:* "A is back, and round-robin resumes on its own."

### 3.9 Browser (optional, a nice visual)
Open **`https://app.teamX.test/api/status`** in Safari and click the **padlock** to show the trusted certificate.

---

## 4. Stop and save the capture

1. Click the red **square** to stop.
2. Choose **File → Save As…**, then `evidence/phase1/video-demo-capture.pcapng`.

---

## 5. Walk through the packets in Wireshark

Paste each filter into the display-filter bar and press Enter.

### 5.1 DNS query and response
```
dns && dns.qry.name matches "(?i)teamx"
```
- Click the **response** packet and expand **Domain Name System → Answers**. Show:
  - `app.teamX.test: type A, class IN, addr 10.7.15.125`
  - `Time to live: 30`
- *Say:* "This is UDP port 53. The query and the answer are both plaintext."

### 5.2 TCP three-way handshake to nginx
```
ip.addr == 10.7.15.125 && tcp.port == 443 && tcp.flags.syn == 1
```
- You'll see **SYN** from `10.7.10.50`, then **SYN, ACK** from `10.7.15.125`.
- Right-click the SYN, choose **Follow → TCP Stream**, close the popup, and the filter becomes `tcp.stream eq N`.
- Show the full sequence: **SYN, SYN-ACK, ACK**, then the TLS packets, then **FIN**.

### 5.3 TLS handshake
```
ip.addr == 10.7.15.125 && tls.handshake
```
- **Client Hello:** expand **TLS → Handshake → Extension: server_name** to show the SNI `app.teamx.test`. Then **Extension: application_layer_protocol_negotiation** shows `h2` and `http/1.1`.
- **Server Hello:** show the chosen cipher suite and TLS version.
- **Certificate** (TLS 1.2 stream from step 3.4): shows the subject `app.teamX.test` and the issuer `mkcert development CA`.

To jump straight to the Client Hello:
```
tls.handshake.type == 1 && tls.handshake.extensions_server_name matches "(?i)teamx"
```

### 5.4 Encrypted application data
```
ip.addr == 10.7.15.125 && tls.record.content_type == 23
```
*Say:* "After the handshake, everything is **Application Data**. The HTTP request, the `X-Backend` header and the JSON body are all encrypted, so Wireshark can't read them."

### 5.5 Compare: plain HTTP is readable
```
http && ip.addr == 10.7.15.125
```
- Open the `GET /api/status` from step 3.2. The headers, `X-Backend` and the JSON body are all **visible in plaintext**.
- *Say:* "That's the difference TLS makes."

### 5.6 Big-picture views (good for the video)
- **Statistics → Conversations → IPv4**: shows Mac 1 talking to `10.7.15.125` (nginx). The client never talks to Mac 3 directly.
- **Statistics → Flow Graph** with the filter `tcp.stream eq N` is a ladder diagram of the handshake and the data.
- **Statistics → Protocol Hierarchy** breaks the capture down into DNS, TCP and TLS.

---

## 6. (Optional) Capture the nginx → backend hop on Mac 2

The client only sees encrypted traffic to nginx. Capturing on **Mac 2** (`en0`) shows the internal hop, where nginx terminates TLS and forwards **plain HTTP/1.1** to Mac 3.

Filter:
```
ip.addr == 10.7.12.174 && (tcp.port == 3001 || tcp.port == 3002)
```
- `http` packets show `GET /api/status`, sent alternately to `:3001` and `:3002`. That's round-robin, visible on the wire.
- During failover, connections to `:3001` get a **RST** (refused), and nginx retries on `:3002`.

---

## 7. (Optional) Decrypt the TLS traffic in Wireshark

macOS's built-in curl (LibreSSL) can't export TLS session keys. Homebrew's curl can:
```bash
brew install curl
export SSLKEYLOGFILE=~/tls-keys.log
/opt/homebrew/opt/curl/bin/curl -s https://app.teamX.test/api/status
```
Then in Wireshark, go to **Settings → Protocols → TLS → (Pre)-Master-Secret log filename**, choose `~/tls-keys.log`, and click OK. The **Application Data** packets become readable **HTTP2** frames.

---

## 8. Suggested video order (~5 min)

| Time | Show |
| --- | --- |
| 0:00 – 0:30 | Intro + architecture (3 Macs, roles, IPs) |
| 0:30 – 1:30 | Configs on Mac 1 / 2 / 3 (section 1) |
| 1:30 – 1:45 | Start the Wireshark capture (section 2) |
| 1:45 – 3:30 | curl commands: DNS, HTTPS, HTTP versions, load balancing, cache, failover (section 3) |
| 3:30 – 4:45 | Wireshark walkthrough: DNS, TCP handshake, TLS, encrypted vs plain (section 5) |
| 4:45 – 5:00 | Wrap-up: what each layer proved |

## 9. Quick troubleshooting during recording

| Problem | Fix |
| --- | --- |
| No DNS packets in Wireshark | Make sure **`lo0`** is selected, and flush the DNS cache before running `dig`. |
| `curl` hangs | The Wi-Fi is slow. Press `Ctrl+C` and retry, or add `-m 10`. |
| `504 Gateway Time-out` | Mac 3's IP changed or the backends stopped. Check `ipconfig getifaddr en0` on Mac 3. |
| `Could not resolve host` | Run `sudo brew services restart dnsmasq` on Mac 1 and flush the DNS cache. |
| `SSL certificate problem` | The mkcert CA isn't trusted on this Mac. Run `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain tls/mkcert-rootCA.pem`. |
| Wireshark shows no interfaces | Reinstall Wireshark's **ChmodBPF** (Wireshark → *Install ChmodBPF*), then log out and back in. |
