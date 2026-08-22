#!/usr/bin/env bash
# Legacy Let's Encrypt on-server HTTPS (requires free port 443 on the VPS).
# SSH currently uses port 443 on this server — use Cloudflare instead:
#   bash scripts/contabo/setup-cloudflare-https.sh

echo "Use Cloudflare HTTPS instead (SSH occupies port 443 on this VPS):" >&2
echo "  bash scripts/contabo/setup-cloudflare-https.sh" >&2
exit 1
