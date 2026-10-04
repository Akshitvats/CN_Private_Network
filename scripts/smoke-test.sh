#!/bin/bash
# Run from any CLIENT Mac once Tasks A-D are done, to sanity-check the
# whole chain before moving on to TLS (Task E).
# Usage: ./smoke-test.sh teamX.test
set -euo pipefail

DOMAIN="${1:-teamX.test}"

echo "== 1. DNS resolution =="
DNS_RESULT="$(dscacheutil -q host -a name "app.$DOMAIN" | awk '/ip_address:/{print $2}')"
if [ -z "$DNS_RESULT" ]; then
  echo "ERROR: macOS could not resolve app.$DOMAIN. Set this client's DNS to the DNS Mac's LAN IP (127.0.0.1 only on the DNS Mac) and remove public secondary resolvers." >&2
  exit 1
fi
printf '%s\n' "$DNS_RESULT"

echo ""
echo "== 2. HTTP through the load balancer (5 requests) =="
for i in 1 2 3 4 5; do
  curl --fail --silent --show-error --connect-timeout 3 --max-time 10 "http://app.$DOMAIN/api/status"
  echo ""
done

echo ""
echo "== 3. Response headers (Cache-Control, X-Backend) =="
curl --fail --silent --show-error --connect-timeout 3 --max-time 10 --head "http://app.$DOMAIN/api/status"
