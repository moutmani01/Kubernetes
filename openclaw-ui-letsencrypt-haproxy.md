# OpenClaw UI on HTTPS with Let's Encrypt (HAProxy)

## What was configured

This VM already had the OpenClaw UI listening only on localhost:

- OpenClaw UI: `127.0.0.1:18789`
- Public TLS frontend: HAProxy on `:443`
- Public hostname: `mahfoud-openclaw.eastus.cloudapp.azure.com`

Instead of replacing the working frontend with nginx, the safer approach was to keep HAProxy on port 443 and replace the self-signed certificate with a Let's Encrypt certificate.

## Result

The live certificate now serves this hostname:

- `https://mahfoud-openclaw.eastus.cloudapp.azure.com/`

Certificate details at the time of configuration:

- Subject: `CN=mahfoud-openclaw.eastus.cloudapp.azure.com`
- Issuer: `C=US, O=Let's Encrypt, CN=YE2`
- Valid from: `2026-06-15 18:08:39 GMT`
- Valid until: `2026-09-13 18:08:38 GMT`

## Why HAProxy was kept instead of nginx

Nginx was not actually installed on this server. The working internet-facing service on port 443 was already:

- `haproxy`

Changing the internet-facing reverse proxy from HAProxy to nginx would have added unnecessary risk and downtime.

## Important network note

Let's Encrypt HTTP validation on port 80 did **not** work because inbound port 80 was not reachable from the internet.

Because port 443 was reachable, the certificate was issued using the **TLS-ALPN challenge** on port 443 instead.

That means:

- port 80 is **not required** for this setup
- renewal uses port 443
- HAProxy must be stopped briefly during issuance/renewal if using standalone TLS-ALPN on the same port

## Current HAProxy config

Current main config file:

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

## Certificate storage

HAProxy serves these files:

- `/etc/haproxy/certs/openclaw-ui.crt`
- `/etc/haproxy/certs/openclaw-ui.key`
- `/etc/haproxy/certs/openclaw-ui.pem`

The PEM file is built as:

```bash
cat /etc/haproxy/certs/openclaw-ui.crt /etc/haproxy/certs/openclaw-ui.key > /etc/haproxy/certs/openclaw-ui.pem
```

## Backups created

Backups were saved under:

- `/root/backups/letsencrypt-haproxy/`

That includes backups of:

- HAProxy config
- previous self-signed cert
- previous key
- previous PEM bundle

## ACME client installed

`certbot` was installed first, but it could not complete validation because Azure/networking blocked inbound port 80.

The working solution uses `acme.sh`, installed here:

- `/root/.acme.sh/acme.sh`

The certificate is managed here:

- `/root/.acme.sh/mahfoud-openclaw.eastus.cloudapp.azure.com_ecc/`

## Commands used to issue the certificate

### 1) Install acme.sh

```bash
mkdir -p /tmp/acme-install
cd /tmp/acme-install
curl -fsSL https://github.com/acmesh-official/acme.sh/archive/master.tar.gz -o acme.tar.gz
tar -xzf acme.tar.gz
cd acme.sh-master
./acme.sh --install --home /root/.acme.sh --config-home /root/.acme.sh --accountemail ''
```

### 2) Set Let's Encrypt as the CA and register the account

```bash
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
/root/.acme.sh/acme.sh --register-account --server letsencrypt
```

### 3) Stop HAProxy and issue the cert with TLS-ALPN on 443

```bash
systemctl stop haproxy
/root/.acme.sh/acme.sh --issue --alpn -d mahfoud-openclaw.eastus.cloudapp.azure.com --server letsencrypt
```

### 4) Install the cert into HAProxy paths

```bash
/root/.acme.sh/acme.sh --install-cert -d mahfoud-openclaw.eastus.cloudapp.azure.com \
  --key-file /etc/haproxy/certs/openclaw-ui.key \
  --fullchain-file /etc/haproxy/certs/openclaw-ui.crt
```

### 5) Rebuild the HAProxy PEM bundle and start HAProxy

```bash
cat /etc/haproxy/certs/openclaw-ui.crt /etc/haproxy/certs/openclaw-ui.key > /etc/haproxy/certs/openclaw-ui.pem
chmod 600 /etc/haproxy/certs/openclaw-ui.pem /etc/haproxy/certs/openclaw-ui.key
chmod 644 /etc/haproxy/certs/openclaw-ui.crt
haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d
systemctl start haproxy
```

## Renewal configuration

`acme.sh` originally installed a default root cron entry, but that default job is **not sufficient** for this setup because HAProxy already owns port 443.

The server is now configured to use this root cron entry instead:

```cron
6 18 * * * /usr/local/bin/renew-openclaw-ui-cert.sh >/var/log/renew-openclaw-ui-cert.log 2>&1
```

Current certificate listing:

```bash
/root/.acme.sh/acme.sh --list
```

At the time of setup, renewal target was:

- `2026-08-14T22:49:54Z`

## Very important: renewal behavior

Because the cert uses **standalone TLS-ALPN on port 443**, `acme.sh` needs to bind to port 443 during renewal.

That means **HAProxy must not already own port 443 during the validation step**.

### Installed renewal script

This wrapper has been installed so renewal is reliable:

```bash
cat >/usr/local/bin/renew-openclaw-ui-cert.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DOMAIN="mahfoud-openclaw.eastus.cloudapp.azure.com"

systemctl stop haproxy
trap 'systemctl start haproxy >/dev/null 2>&1 || true' EXIT

/root/.acme.sh/acme.sh --renew -d "$DOMAIN" --alpn --server letsencrypt
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/haproxy/certs/openclaw-ui.key \
  --fullchain-file /etc/haproxy/certs/openclaw-ui.crt

cat /etc/haproxy/certs/openclaw-ui.crt /etc/haproxy/certs/openclaw-ui.key > /etc/haproxy/certs/openclaw-ui.pem
chmod 600 /etc/haproxy/certs/openclaw-ui.pem /etc/haproxy/certs/openclaw-ui.key
chmod 644 /etc/haproxy/certs/openclaw-ui.crt
haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d
systemctl start haproxy
trap - EXIT
EOF

chmod 700 /usr/local/bin/renew-openclaw-ui-cert.sh
```

The root crontab was updated to call this wrapper instead of the default acme.sh cron job:

```cron
6 18 * * * /usr/local/bin/renew-openclaw-ui-cert.sh >/var/log/renew-openclaw-ui-cert.log 2>&1
```

## Verification commands

### Check service state

```bash
systemctl status haproxy --no-pager
```

### Validate HAProxy config

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d
```

### Inspect the served certificate locally

```bash
openssl x509 -in /etc/haproxy/certs/openclaw-ui.crt -noout -subject -issuer -dates -fingerprint -sha256
```

### Test HTTPS from the server

```bash
curl -Iv https://mahfoud-openclaw.eastus.cloudapp.azure.com/
```

## If you want zero-downtime renewal later

This current method works, but it may require a short HAProxy stop/restart during renewal.

If you want to avoid that, better long-term options are:

1. Allow inbound port 80 and use HTTP challenge
2. Use DNS challenge with your DNS provider API
3. Build a more advanced HAProxy ACME/TLS-ALPN routing setup

For most demo/test environments, the current setup is fine.

## Current status summary

- Public HTTPS works
- Certificate is now from Let's Encrypt
- OpenClaw UI is still only exposed behind HAProxy
- Backend remains on `127.0.0.1:18789`
- Existing self-signed certificate files were backed up
- Port 80 is not open/reachable, so HTTP-01 is not usable here

## Suggested next hardening steps

- restrict access to the UI by IP if possible
- add HTTP basic auth or an additional auth gate if appropriate
- consider Azure NSG rules limiting source IPs
- enable fail2ban or rate limiting if this stays internet-facing
- prefer DNS challenge later if you want cleaner automated renewals
