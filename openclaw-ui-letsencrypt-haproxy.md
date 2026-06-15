# OpenClaw UI on HTTPS with Let's Encrypt (HAProxy)

## What was configured

This VM keeps the OpenClaw UI bound only to localhost:

- OpenClaw UI backend: `127.0.0.1:18789`
- Public TLS frontend: HAProxy on `:443`
- Public hostname: `mahfoud-openclaw.eastus.cloudapp.azure.com`

The public endpoint is HAProxy terminating TLS and reverse proxying to the local OpenClaw UI.

## Live result

Public URL:

- `https://mahfoud-openclaw.eastus.cloudapp.azure.com/`

At verification time, the live certificate served by HAProxy was:

- Subject: `CN=mahfoud-openclaw.eastus.cloudapp.azure.com`
- Issuer: `C=US, O=Let's Encrypt, CN=YE2`
- Valid from: `2026-06-15 18:08:39 GMT`
- Valid until: `2026-09-13 18:08:38 GMT`

## Current HAProxy config

Main config file:

- `/etc/haproxy/haproxy.cfg`

Relevant structure:

```haproxy
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    maxconn 4000
    user haproxy
    group haproxy
    daemon
    stats socket /var/lib/haproxy/stats mode 660 level admin
    ssl-default-bind-ciphers PROFILE=SYSTEM
    ssl-default-server-ciphers PROFILE=SYSTEM

defaults
    mode http
    log global
    option httplog
    option dontlognull
    option forwardfor except 127.0.0.0/8
    timeout connect 10s
    timeout client 1m
    timeout server 1m

frontend openclaw_https
    bind *:443 ssl crt /etc/haproxy/certs/openclaw-ui.pem
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Host %[req.hdr(host)]
    default_backend openclaw_ui

backend openclaw_ui
    server openclaw_local 127.0.0.1:18789 check
```

## Certificate files used by HAProxy

HAProxy serves these files:

- `/etc/haproxy/certs/openclaw-ui.crt`
- `/etc/haproxy/certs/openclaw-ui.key`
- `/etc/haproxy/certs/openclaw-ui.pem`

The PEM bundle is built as:

```bash
cat /etc/haproxy/certs/openclaw-ui.crt /etc/haproxy/certs/openclaw-ui.key > /etc/haproxy/certs/openclaw-ui.pem
```

## Important network constraint

Inbound port 80 was not reachable from the internet during setup.

That means:

- HTTP-01 validation failed
- standard Certbot standalone/webroot on port 80 was not suitable
- the working certificate path used the **TLS-ALPN challenge on port 443**

Because HAProxy normally owns port 443, renewal needs to free that port briefly while ACME validation runs.

## What is actually managing the live certificate

The live certificate is managed by:

- `acme.sh`

Installed path:

- `/root/.acme.sh/acme.sh`

Current certificate listing:

```bash
/root/.acme.sh/acme.sh --list
```

Current expected renew target at the time of setup:

- `2026-08-14T22:49:54Z`

## Why Certbot is not the active manager here

`certbot` is installed on the VM, but it is **not** the active certificate manager for the live HAProxy certificate.

What was observed:

- `certbot certificates` returned no managed certificates
- `/etc/letsencrypt/renewal/` had no certificate renewal lineage for this hostname
- the live HAProxy certificate fingerprint matched the `acme.sh` certificate exactly

So the correct thing was to keep `acme.sh` as the source of truth and configure renewal around that, instead of creating a fake or split management path.

## Renewal setup implemented

### Renewal wrapper script

Installed file:

- `/usr/local/bin/renew-openclaw-ui-cert.sh`

Content:

```bash
#!/usr/bin/env bash
set -euo pipefail
DOMAIN="mahfoud-openclaw.eastus.cloudapp.azure.com"
ACME="/root/.acme.sh/acme.sh"
CERT_DIR="/etc/haproxy/certs"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
HAPROXY_CFGDIR="/etc/haproxy/conf.d"

if ! [ -x "$ACME" ]; then
  echo "acme.sh not found at $ACME" >&2
  exit 1
fi

systemctl stop haproxy
trap 'systemctl start haproxy >/dev/null 2>&1 || true' EXIT

"$ACME" --renew -d "$DOMAIN" --alpn --server letsencrypt
"$ACME" --install-cert -d "$DOMAIN" \
  --key-file "$CERT_DIR/openclaw-ui.key" \
  --fullchain-file "$CERT_DIR/openclaw-ui.crt"

cat "$CERT_DIR/openclaw-ui.crt" "$CERT_DIR/openclaw-ui.key" > "$CERT_DIR/openclaw-ui.pem"
chmod 600 "$CERT_DIR/openclaw-ui.pem" "$CERT_DIR/openclaw-ui.key"
chmod 644 "$CERT_DIR/openclaw-ui.crt"
haproxy -c -f "$HAPROXY_CFG" -f "$HAPROXY_CFGDIR"
systemctl start haproxy
trap - EXIT
```

### Root cron entry

Installed root crontab entry:

```cron
6 18 * * * /usr/local/bin/renew-openclaw-ui-cert.sh >/var/log/renew-openclaw-ui-cert.log 2>&1
```

This is the active renewal mechanism for the OpenClaw UI certificate on this VM.

## Verification commands

### Check HAProxy is active

```bash
systemctl status haproxy --no-pager
```

### Validate HAProxy config

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d
```

### Inspect the installed certificate

```bash
openssl x509 -in /etc/haproxy/certs/openclaw-ui.crt -noout -subject -issuer -dates -fingerprint -sha256
```

### Check acme.sh inventory

```bash
/root/.acme.sh/acme.sh --list
```

### Check the active root crontab

```bash
crontab -l
```

### Test the public endpoint

```bash
curl -Iv https://mahfoud-openclaw.eastus.cloudapp.azure.com/
```

## Operational note about renewals

Because this renewal method uses **TLS-ALPN on port 443**, HAProxy is stopped briefly during renewal so `acme.sh` can bind to 443 and complete validation.

That means:

- renewal is automated
- but not truly zero-downtime
- for a demo/test lab this is usually acceptable

## Better long-term options

If this becomes more important later, cleaner options are:

1. allow inbound port 80 and switch to HTTP-01 validation
2. use a DNS challenge with the DNS provider API
3. build a more advanced HAProxy/ACME integration that avoids service interruption

## Current status summary

- Public HTTPS works
- HAProxy serves a valid Let's Encrypt certificate
- OpenClaw backend remains on `127.0.0.1:18789`
- Live certificate management is done by `acme.sh`
- Renewal is automated through a root cron wrapper script
- Port 80 is not usable for HTTP-01 in the current environment
