# Phase I Evidence — Computer Networks Private Network Platform

Collected on **Satyam Kumar's Mac (Mac 1)** on 5 October 2026. Names, enrollment numbers, and roles match the [architecture](../../README.md#architecture).

---

## Team & Network Configuration

| Role | Member | Enrollment | Mac & IP Address | Service / Function |
| :--- | :--- | :--- | :--- | :--- |
| **Tech Lead** | **Satyam Kumar** | 2401010428 | **Mac 1** (`10.7.10.50`) | Private DNS Server (`dnsmasq`), Test Client, Wireshark Captures |
| **Edge / Proxy** | **Krishna Verma** | 2401010240 | **Mac 2** (`10.7.15.125`) | Reverse Proxy & Load Balancer (`nginx`), mkcert CA & TLS (443/80) |
| **Backends** | **Akshit Vats** | _TBD_ | **Mac 3** (`10.7.12.174`) | Backend A (`:3001`) & Backend B (`:3002`) (Python Flask) |

- **Private Domain:** `app.teamX.test` and `api.teamX.test`
- **Private Subnet:** `10.7.0.0/16` (College Wi-Fi LAN)

---

## Summary of Verified Results

- **[Full Terminal Output](terminal-output.txt):** Complete raw logs for all tasks (A through G), verifying DNS resolution, round-robin load balancing, trusted HTTPS, HTTP versions, and caching.
- **[Smoke Test Script](../../scripts/smoke-test.sh):** Automated sanity check verifying DNS, HTTP (5 requests), HTTP headers, HTTPS (5 requests), HTTPS HTTP/2 headers, and conditional cache requests.
- **Task A (LAN Connectivity):** Verified active network interface (`en0`), IP `10.7.10.50`, gateway `10.7.0.1`, and 0.0% packet loss pinging Mac 2 (`10.7.15.125`) and Mac 3 (`10.7.12.174`).
- **Task B (Private DNS):** Verified `app.teamX.test` and `api.teamX.test` resolving to `10.7.15.125` with 30s TTL via `dnsmasq` (`10.7.10.50`). Verified public isolation with `NXDOMAIN` on `8.8.8.8`.
- **Task C (Direct Backends):** Verified direct HTTP connectivity to Backend A (`10.7.12.174:3001` → `X-Backend: A`) and Backend B (`10.7.12.174:3002` → `X-Backend: B`).
- **Task D (Load Balancing):** Verified round-robin distribution through Nginx reverse proxy alternating between `X-Backend: B` and `X-Backend: A`.
- **Task E (Trusted HTTPS):** Verified TLS 1.3 / ALPN `h2` handshake with trusted mkcert certificate (`SSL certificate verify ok` without `-k`), negotiating `HTTP/2 200`.
- **Task F (Caching & Conditional GET):** Verified `Cache-Control: public, max-age=60`, `ETag: "cn-cache-v1"`, and `HTTP/2 304 Not Modified` on conditional `If-None-Match` request.
- **Task G (TLS 1.2 Handshake):** Verified TLS 1.2 cipher suite negotiation (`TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`) and application data transmission.

---

## Primary Packet Captures

1. **[phase1-capture-en0-lo0.pcapng](phase1-capture-en0-lo0.pcapng)** — Combined multi-interface capture recording DNS queries over loopback/LAN and TCP/TLS handshakes to edge.
2. **[phase1-capture-en0.pcapng](phase1-capture-en0.pcapng)** — LAN interface capture of real-time client traffic to edge (`10.7.15.125:443`) and DNS server (`10.7.10.50:53`).

### Packet Inspection & Wireshark Filter Mapping

| Traffic Type | Wireshark Filter | Key Details / Flow |
| :--- | :--- | :--- |
| **DNS Query / Response** | `dns && ip.addr == 10.7.10.50` | `app.teamX.test` query to port 53; A record `10.7.15.125`, TTL 30s |
| **Public DNS Isolation** | `dns && ip.addr == 8.8.8.8` | Query returned `NXDOMAIN` (private name unresolvable publicly) |
| **TCP 3-Way Handshake** | `tcp.port == 443 && tcp.flags.syn == 1` | `SYN` $\to$ `SYN-ACK` $\to$ `ACK` between `10.7.10.50` and `10.7.15.125` |
| **TLS Handshake & Encryption** | `tcp.port == 443 && tls` | `ClientHello` (SNI: `app.teamX.test`), `ServerHello`, Certificate, Encrypted Application Data |
| **Full Stream Inspection** | `tcp.stream eq 0` | Follow complete TCP/TLS stream from handshake to teardown |

---

## Screenshots Overview

All screenshots are stored in [screenshots/](screenshots/):

| Task / Evidence | File | Description |
| :--- | :--- | :--- |
| **Task A: LAN** | [task-a-lan.jpg](screenshots/task-a-lan.jpg) | Network interface configuration, IP assignment, gateway route, and ICMP pings |
| **Task B: DNS** | [task-b-dns.jpg](screenshots/task-b-dns.jpg) | Private DNS query (TTL 30s) and public DNS NXDOMAIN verification |
| **Task C: Backends** | [task-c-backends.jpg](screenshots/task-c-backends.jpg) | Direct backend health checks on ports 3001 and 3002 |
| **Task D: Load Balancing** | [task-d-load-balancing.jpg](screenshots/task-d-load-balancing.jpg) | 6 sequential curl requests showing round-robin distribution between A & B |
| **Task E: HTTPS** | [task-e-https.jpg](screenshots/task-e-https.jpg) | Verbose HTTPS verification without `-k`, showing TLS 1.3, ALPN h2, and cert trust |
| **Task F: Caching** | [task-f-caching.jpg](screenshots/task-f-caching.jpg) | Cache headers, ETag validation, and 304 Not Modified conditional responses |
| **Task G: TLS 1.2** | [task-g-tls12-terminal.jpg](screenshots/task-g-tls12-terminal.jpg) | Explicit TLS 1.2 request and response verification |
| **Wireshark: Private DNS** | [wireshark-dns-private-server.jpg](screenshots/wireshark-dns-private-server.jpg) | Wireshark packet capture showing private DNS query and response (TTL 30s) |
| **Wireshark: Public DNS** | [wireshark-dns-public-nxdomain.jpg](screenshots/wireshark-dns-public-nxdomain.jpg) | Wireshark packet capture showing public resolver returning NXDOMAIN |
| **Wireshark: TCP & TLS Handshake** | [wireshark-tcp-tls-handshake.jpg](screenshots/wireshark-tcp-tls-handshake.jpg) | Wireshark packet capture showing TCP 3-way handshake and TLS Client/Server Hello |
| **Wireshark: Full Stream** | [wireshark-full-tls12-stream.jpg](screenshots/wireshark-full-tls12-stream.jpg) | Wireshark stream view showing complete TLS session with encrypted records |
