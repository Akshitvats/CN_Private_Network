# TLS Setup, Certificate Generation & Trust Guide

This document explains the steps to generate self-signed/local Certificate Authority (CA) certificates for the private domain (`app.teamX.test`), configure Nginx, and establish trust on macOS.

---

## 1. Generate SSL Certificate for the Domain

Run the following OpenSSL command on the machine running Nginx:

```bash
# Create directory for certificates
mkdir -p tls
cd tls

# Generate private key and self-signed certificate with Subject Alternative Names (SAN)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout edge.key \
  -out edge.crt \
  -subj "/C=IN/ST=State/L=City/O=CNProject/CN=app.teamX.test" \
  -addext "subjectAltName=DNS:app.teamX.test,DNS:api.teamX.test,IP:10.7.15.125"
```

> **Security Note:** The private key `edge.key` must remain strictly on the Nginx machine and should **never** be committed to Git. Only the public certificate `edge.crt` is shared.

---

## 2. Configure Nginx with SSL

In your Nginx server configuration (`/opt/homebrew/etc/nginx/servers/cn-project.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name app.teamX.test api.teamX.test;

    ssl_certificate /path/to/tls/edge.crt;
    ssl_certificate_key /path/to/tls/edge.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://backend_pool;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Reload Nginx:
```bash
sudo brew services restart nginx
```

---

## 3. Trust the Public Certificate on macOS

To allow `curl` and browsers to validate the certificate without `-k` (insecure flag):

1. **Via Command Line:**
   ```bash
   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /path/to/tls/edge.crt
   ```
2. **Via Keychain Access App (GUI):**
   - Open **Keychain Access** on macOS.
   - Drag and drop `edge.crt` into the **System** or **login** keychain.
   - Double-click the imported certificate $\to$ Expand **Trust** $\to$ Set **When using this certificate** to **Always Trust**.

---

## 4. Verification

Test with `curl` without using `-k`:

```bash
curl -v https://app.teamX.test/api/status
```

**Expected verification output:**
- `* Server certificate:`
- `*  subject: CN=app.teamX.test`
- `*  SSL certificate verify ok.`
- `* Using HTTP2, server supports multiplexing`
- `< HTTP/2 200`

---

## 5. Phase 2: one certificate, two edges

- The edge certificate is issued by **Krishna's mkcert CA** (`mkcert app.teamX.test api.teamX.test`). Its public CA
  certificate is committed as [`tls/mkcert-rootCA.pem`](../tls/mkcert-rootCA.pem); the edge certificate (public part)
  as [`tls/app.teamX.test.crt`](../tls/app.teamX.test.crt). Private keys are never committed.
- `scripts/deploy.sh` installs the **same certificate and key** on edge1 (Krishna's Mac) and the standby edge2
  (Akshit's Mac), copying the key host-to-host through a private temp directory. TLS validates the *name* in the SAN,
  not the IP, so the Extension E DNS cutover is invisible to clients.
- `scripts/deploy.sh --tls` re-issues the certificate with mkcert on Krishna's Mac (e.g. before it expires on
  4 Jan 2029) and redistributes it.
- Clients trust the CA once with `sudo scripts/phase2/client-setup.sh` (it skips the step if already trusted).
- Check from any client: `openssl s_client -connect app.teamX.test:443 -servername app.teamX.test -CAfile tls/mkcert-rootCA.pem -verify_hostname app.teamX.test`
  → `Verify return code: 0 (ok)`.
