# Viva Preparation — Phase 1 + Phase 2

Every member must be able to explain the **whole** system, not only their own Mac.

## The request journey (say it in one breath)

"The client asks our DNS server on Satyam's Mac — UDP port 53 — where `app.teamX.test` is. dnsmasq answers
`10.7.15.23`, Krishna's Mac, with a 30-second TTL, and the client caches it. The client opens a TCP connection to
port 443 (SYN, SYN-ACK, ACK), then does a TLS handshake: ClientHello with SNI `app.teamX.test`, ServerHello, the
certificate signed by our own CA — which every client trusts — key exchange, Finished. Inside the encrypted
tunnel it sends an HTTP/2 GET. nginx terminates TLS, picks Backend A or B round-robin, forwards the request as plain
HTTP/1.1 to Akshit's Mac on port 3001 or 3002, and returns the JSON with `X-Backend` and `X-Edge` headers."

## Phase 1 questions

| Question | Short answer |
| --- | --- |
| DNS resolution vs the HTTPS connection? | DNS only finds the IP (a directory lookup, UDP 53). The connection is a separate TCP + TLS session to that IP. Wrong DNS → wrong place; DNS down → no connection at all. |
| Why `.test` and not `.local`? | `.test` is reserved (RFC 2606) and never exists publicly; `.local` belongs to mDNS/Bonjour on macOS. |
| Why does the client never need backend IPs? | It only talks to the edge (reverse proxy). nginx holds the upstream list — backends can change without touching clients. |
| What is TLS termination? | TLS ends at nginx: the client↔edge hop is encrypted, nginx decrypts, then talks plain HTTP to the backends inside the LAN. |
| How does the client trust our cert? | The cert is signed by Krishna's mkcert CA; that CA's certificate is in each client's System keychain (`client-setup.sh`). curl verifies chain + name (SAN) — no `-k`. |
| TLS handshake steps? | ClientHello (versions, ciphers, SNI, ALPN h2) → ServerHello → Certificate → key exchange (ECDHE) → Finished. In TLS 1.3 everything after ServerHello is encrypted, so our capture forces TLS 1.2 to show the Certificate. |
| Why can't Wireshark show the HTTP? | It is inside TLS: "Application Data" records are encrypted with session keys only the client and nginx have. |
| Fresh hit vs conditional request vs full request? | Fresh: within `max-age=60` the client reuses its copy, no request at all. Conditional: after that it sends `If-None-Match: "cn-cache-v1"`; server answers **304** with no body. Full: no cached copy → 200 with the body. |
| Socket pair? | (client IP, ephemeral port, server IP, server port), e.g. `10.7.15.19:53151 ↔ 10.7.15.23:443`. |
| Sequence/ACK numbers? | Each side numbers its bytes; ACK = next byte expected. Lost segments are retransmitted until ACKed → reliability; window size → flow control. |
| HTTP/1.1 vs HTTP/2? | HTTP/2 is binary, multiplexes many streams over one TCP connection, compresses headers; negotiated with ALPN in the TLS handshake. HTTP/3 runs over QUIC (UDP). |

## Phase 2 questions

| Question | Short answer |
| --- | --- |
| DNS failure vs application failure? | DNS failure: the name cannot be resolved, nothing starts (curl error 6). Application failure: name resolves, TCP and TLS work, but the edge returns **502** because no backend answers. |
| How does the client use the backup DNS? | Both servers are configured; macOS gets "port unreachable"/timeout from the primary and uses the secondary (it may even query both and take the first answer). Both hold identical records. |
| What is TTL and why does it matter for migration? | How long a resolver/client may cache an answer. After a record change, clients keep the old IP for up to one TTL. Before a migration you lower the TTL (we use 30 s) so the cutover propagates quickly; after it, keep the old server running for one TTL. |
| How did you change a record live? | `cn.sh dns-record <ip>` rewrites `teamX.hosts` and sends SIGHUP; dnsmasq re-reads it and clears its cache. Done on **both** resolvers so they never disagree. |
| Flush vs waiting? | `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` drops the client cache → immediate. In production you can't flush every user's cache, so you wait one TTL. |
| How does pf isolate the backends? | Rules in anchor `com.apple/cn-backend-isolation`: pass `lo0`, pass TCP 3001/3002 from edge1 only, `block drop` everyone else. Clients' SYNs are silently dropped → timeout (curl exit 28), not refused (exit 7). Rollback flushes the anchor and releases our pf reference. |
| Timeout vs refused? | Refused = the host answered with RST (nothing listening). Timeout = no answer at all (filtered by a firewall, or host down). |
| How does nginx detect a dead backend? | Passive health checks: a failed connect counts as a failure; `max_fails=1` → marked down for `fail_timeout=10s`; `proxy_next_upstream` retries the same request on the other backend, so the user sees 200. After 10 s it tries A again and A rejoins. |
| What is still a single point of failure? | The edge: one nginx on Krishna's Mac behind one DNS record. Fix: two edges with a floating IP (VRRP/keepalived) or a managed LB with health-checked DNS. Also: both backends on one Mac. |
| How does the standby edge serve HTTPS with the same cert? | We copy the same certificate + key to it. TLS validates the **name** (`app.teamX.test` in the SAN), not the IP, so moving the A record is invisible to TLS. |
| Why does edge1 run as root? | macOS Local Network privacy: a non-Apple daemon started over SSH loses LAN access when the session ends (`No route to host`). Root processes are exempt. We found it with `diagnose.sh` → 502 → nginx error log → reproduced with `openssl s_client`. |
| How do you diagnose an injected fault? | Bottom-up, stop at the first failure: my network → DNS (`dig @each server`, system resolver) → IP (`ping`) → TCP (`nc -z`, refused vs timeout) → TLS (`openssl s_client -verify_hostname`) → HTTP (status code, `X-Edge`) → backends (`X-Backend`, nginx error log). `scripts/diagnose.sh` automates exactly this. |

## OSI / TCP-IP mapping

| Protocol | TCP/IP layer | OSI layer |
| --- | --- | --- |
| DNS, HTTP/1.1, HTTP/2, REST | Application | 7 |
| TLS | between Application and Transport | 5/6 (session/presentation) |
| TCP, UDP (ports 53, 443, 3001, 3002) | Transport | 4 |
| IPv4 (10.7.0.0/19) | Internet | 3 |
| Wi-Fi 802.11, ARP/MAC | Link | 2 (+1) |
