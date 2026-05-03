# singbox-installer.sh

A single-script sing-box 1.11.0 multi-protocol installer and manager for Linux VPS. Installs one or more proxy inbounds (`vless-reality`, `vmess-ws`, `trojan-ws`, `hysteria`, `hysteria2`, `shadowsocks`) with automatic generation of a master client config and per-install standalone client configs.

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Initial setup](#2-initial-setup)
3. [Subcommand reference](#3-subcommand-reference)
4. [Output files explained](#4-output-files-explained)
5. [Common workflows](#5-common-workflows)
6. [Protocol reference](#6-protocol-reference)
7. [Port and transport rules](#7-port-and-transport-rules)
8. [SNI management for vless-reality](#8-sni-management-for-vless-reality)
9. [State directory and credential lifecycle](#9-state-directory-and-credential-lifecycle)
10. [Importing client configs into apps](#10-importing-client-configs-into-apps)
11. [Troubleshooting](#11-troubleshooting)
12. [Migration from older script versions](#12-migration-from-older-script-versions)
13. [Security notes](#13-security-notes)
14. [FAQ](#14-faq)

---

## 1. Prerequisites

### Operating system
Tested on Ubuntu 22.04 / 24.04 and Debian 12. Should work on any Debian-family distro with `apt`.

### Auto-installed on first run
- `curl`, `wget`, `tar`, `jq`, `uuid-runtime`, `openssl`, `iproute2`, `xxd`

### Required ahead of time
- **Root access** on the server.
- **A public IPv4** detectable from `api.ipify.org`, `v4.ident.me`, or `checkip.amazonaws.com`.
- **Open firewall** on the ports you'll use. The script attempts auto-open via `ufw` / `iptables` / `firewalld`. Cloud provider external firewalls (DigitalOcean, AWS, Hetzner, etc.) must be opened manually.

The script auto-downloads the sing-box tarball from GitHub if absent:
```bash
mkdir -p /root/singbox_installer
cd /root/singbox_installer
wget https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz
```

To use a mirror:
```bash
SINGBOX_RELEASE_URL=https://your-mirror.example.com/sing-box/v1.11.0 \
    sudo -E bash singbox-installer.sh install vless-reality 443
```

To enforce a specific SHA256:
```bash
SINGBOX_SHA256=<expected-hex> sudo -E bash singbox-installer.sh install vless-reality 443
```

---

## 2. Initial setup

```bash
mkdir -p /root/singbox_installer
cd /root/singbox_installer
chmod +x singbox-installer.sh
sudo bash singbox-installer.sh install vless-reality 443
```

If your server blocks GitHub outbound, pre-download first:
```bash
cd /root/singbox_installer
wget https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz
sudo bash singbox-installer.sh install vless-reality 443
```

The first run installs deps, extracts sing-box to `/usr/local/bin/sing-box`, generates a Reality keypair, picks an SNI, builds server and client configs, installs the systemd unit, opens the firewall, and starts the service. Subsequent installs append a new inbound.

---

## 3. Subcommand reference

All commands: `sudo bash singbox-installer.sh <SUBCOMMAND> [args]`

### `install <PROTOCOL> <PORT> [--sni DOMAIN]`

Install or upsert a single inbound. Tag is auto-derived as `<protocol>-<port>` (e.g. `vless-reality-443`).

- **PROTOCOL** — `vless-reality`, `vmess-ws`, `trojan-ws`, `hysteria`, `hysteria2`, `shadowsocks`
- **PORT** — 1–65535
- **--sni DOMAIN** — forces a specific Reality SNI target (vless-reality only)

Same `<protocol> <port>` re-run is an idempotent upsert.

### `remove <TAG>`

Removes an inbound by tag. Cleans up: server config, master client outbound, selector/urltest references, per-install client file, and all per-port secret files. Service is restarted automatically.

### `list`

Shows: all server inbounds (tag, type, port), master client `proxy` selector contents, and all per-install client config files on disk.

### `show <TAG>`

Prints `/etc/singbox/sing-box-client-<TAG>.txt` to stdout.

```bash
sudo bash singbox-installer.sh show vless-reality-443 > /tmp/jp1-only.json
```

### `show-master`

Prints `/etc/singbox/sing-box-client-master.txt` to stdout.

### `regen-uuid <TAG>`

Rotates credentials for an inbound:

| Protocol | What gets rotated |
|---|---|
| vless-reality | UUID |
| vmess-ws | UUID |
| trojan-ws | password |
| hysteria | password (auth_str) |
| hysteria2 | password |
| shadowsocks | 2022-blake3-aes-256-gcm key |

Server inbound, master client outbound, and per-install client file are all rewritten. Service is restarted.

### `regen-sni <TAG> [--sni DOMAIN]`

Reassigns the Reality SNI for a `vless-reality` inbound. If `--sni` is omitted, picks a fresh unused one from the SNI pool.

### `set-sni-pool <DOMAIN1,DOMAIN2,...>`

Override the default SNI pool. Saved to `/etc/singbox/.state/sni-pool.txt`.

```bash
sudo bash singbox-installer.sh set-sni-pool www.icloud.com,www.bing.com,dl.google.com
```

### `show-sni-pool`

Prints the active SNI pool (custom file or built-in default).

### `doctor`

Health check. Reports: binary version, config paths, systemd unit ExecStart, service status, active listeners, `sing-box check` validation for server and master configs, active SNI pool.

### `service <action>`

Wrapper around `systemctl`:
- `start` / `stop` / `restart`
- `status` — first 20 lines of `systemctl status`
- `logs` — `journalctl -u sing-box -f`

### `help`

Print usage.

### Backwards-compat shorthand

`<PROTOCOL> <PORT>` is treated as `install <PROTOCOL> <PORT>`:
```bash
sudo bash singbox-installer.sh vless-reality 443
```

---

## 4. Output files explained

| Path | Purpose |
|---|---|
| `/usr/local/etc/sing-box/config.json` | **Server config** — systemd runs `sing-box run -c` against this |
| `/etc/singbox/sing-box-client-master.txt` | **Master client config** — all inbounds wired into urltest + selector; use this on phones/multi-node clients |
| `/etc/singbox/sing-box-client-<protocol>-<port>.txt` | **Per-install client config** — standalone single-node config |
| `/etc/systemd/system/sing-box.service` | systemd unit |
| `/etc/singbox/.state/` | Persistent state — Reality keypair, self-signed cert, per-port secrets, SNI overrides |
| `/tmp/singbox-installer.log` | Installer log (truncated each install) |
| `/tmp/singbox.log` | Runtime log from sing-box |

**Master** includes all nodes, urltest/failover, Clash mode support (Direct / Global / Smart), Meta/FB app routing, ad-blocking, geoip-cn routing, and the clash_api endpoint at `127.0.0.1:9090`.

**Per-install** is for isolation testing or handing a single node to a user. Same DNS/routing structure as master, single outbound.

---

## 5. Common workflows

### Primary VLESS Reality + hysteria2 fallback

```bash
sudo bash singbox-installer.sh install vless-reality 443
sudo bash singbox-installer.sh install hysteria2 443
```

The master client `proxy` selector → `auto` urltest → both nodes, probed every 3 minutes.

### Multiple Reality inbounds with different SNIs

```bash
sudo bash singbox-installer.sh install vless-reality 443
sudo bash singbox-installer.sh install vless-reality 8443
sudo bash singbox-installer.sh install vless-reality 2053
```

Or force specific SNIs:
```bash
sudo bash singbox-installer.sh install vless-reality 443  --sni www.icloud.com
sudo bash singbox-installer.sh install vless-reality 8443 --sni www.bing.com
sudo bash singbox-installer.sh install vless-reality 2053 --sni dl.google.com
```

### Customize SNI pool, then install

```bash
sudo bash singbox-installer.sh set-sni-pool www.icloud.com,www.bing.com,dl.google.com,addons.mozilla.org
sudo bash singbox-installer.sh install vless-reality 443
```

### Rotate credentials

```bash
sudo bash singbox-installer.sh regen-uuid vless-reality-443
sudo bash singbox-installer.sh regen-uuid hysteria2-443
sudo bash singbox-installer.sh regen-sni  vless-reality-443
sudo bash singbox-installer.sh show-master > /tmp/master-$(date +%F).json
```

### Decommission a node

```bash
sudo bash singbox-installer.sh remove vless-reality-2053
```

### Health check

```bash
sudo bash singbox-installer.sh doctor
```

### Tail live log

```bash
sudo bash singbox-installer.sh service logs
```

---

## 6. Protocol reference

| Protocol | Transport | Best for | Notes |
|---|---|---|---|
| `vless-reality` | TCP | Primary — best stealth | Forges TLS handshake to a real SNI target. SNI must be reachable from the server. |
| `hysteria2` | UDP | Fast residential ISPs; primary fallback | QUIC-based. UDP can be QoS-throttled by some carriers. |
| `trojan-ws` | TCP | CDN-fronting; rainy-day fallback | Self-signed cert + WS. Works behind Cloudflare. |
| `vmess-ws` | TCP | Client compatibility | Older protocol. VLESS is strictly better on stealth. |
| `hysteria` | UDP | Legacy compat only | Hysteria v1, deprecated upstream. Script warns on install. |
| `shadowsocks` | TCP | Low-overhead bulk forwarding | 2022-blake3-aes-256-gcm. No TLS — DPI can pattern-match SS traffic. |

### Credentials per protocol

| Protocol | Server-side fields | Client connects with |
|---|---|---|
| vless-reality | UUID, Reality keypair, SNI, short_id | UUID, Reality public key, SNI, short_id |
| vmess-ws | UUID, WS path, self-signed cert | UUID, WS path, `insecure: true` |
| trojan-ws | password, WS path, self-signed cert | password, WS path, `insecure: true` |
| hysteria | password (auth_str), self-signed cert, up/down mbps | password, `insecure: true` |
| hysteria2 | password, self-signed cert | password, `insecure: true` |
| shadowsocks | 32-byte base64 key | same key, same method |

---

## 7. Port and transport rules

TCP and UDP on the same port number are independent. Installing `vless-reality 443` (TCP) and `hysteria2 443` (UDP) together is fine.

The collision check catches:
- An existing sing-box inbound on the same port + transport
- A kernel listener from another process on the same port + transport

When the same `<protocol> <port>` is re-run, the script detects it as an idempotent upsert.

---

## 8. SNI management for vless-reality

### How SNI assignment works

1. If `--sni DOMAIN` is passed → use it, save to state.
2. If a saved SNI exists for this port → reuse it.
3. Otherwise → pick from the pool, preferring one not already in use on another inbound.
4. If the pool is exhausted → fall back to `pool[port % len(pool)]`.

### When to rotate SNIs

1. Confirmed GFW pattern-matching on a specific node.
2. CCP plenary / national holiday crackdown periods.
3. Quarterly hygiene.

```bash
sudo bash singbox-installer.sh regen-sni vless-reality-443
sudo bash singbox-installer.sh regen-sni vless-reality-443 --sni www.bing.com
```

### Updating the pool

```bash
sudo bash singbox-installer.sh set-sni-pool $(cat <<EOF | tr '\n' ',' | sed 's/,$//'
www.icloud.com
www.bing.com
dl.google.com
addons.mozilla.org
www.cloudflare.com
EOF
)
```

---

## 9. State directory and credential lifecycle

| File | Contents | Created when |
|---|---|---|
| `reality.keypair` | Reality private + public key | First vless-reality install |
| `self-signed.crt` / `self-signed.key` | Self-signed TLS cert (PEM) | First hy2/trojan/vmess install |
| `uuid-<port>.secret` | UUID for vless/vmess on this port | install / regen-uuid |
| `password-<port>.secret` | Password for trojan/hy/hy2 | install / regen-uuid |
| `ss2022-key-<port>.secret` | 32-byte base64 key for shadowsocks | install / regen-uuid |
| `sni-<port>.txt` | Reality SNI for this port | install / regen-sni |
| `trojan-<port>.path` / `vmess-<port>.path` | Random hex WS path | install |
| `sni-pool.txt` | Custom SNI pool | set-sni-pool |

Re-running `install vless-reality 443` reuses existing secrets — clients don't break. To actually rotate, use `regen-uuid` / `regen-sni`. Running `remove <tag>` deletes the secrets for that port; the next install on that port generates fresh ones.

### Backup

```bash
tar czf /root/singbox-state-backup-$(date +%F).tar.gz \
    /etc/singbox/.state/ \
    /etc/singbox/sing-box-client-master.txt \
    /usr/local/etc/sing-box/config.json
```

---

## 10. Importing client configs into apps

### sing-box for Android / iOS / macOS

1. Profiles → New profile → Type: Local
2. Paste JSON from `show-master` or import a file
3. Save → tap profile → toggle Start

### NekoBox / NekoRay (desktop)

- **Program → From clipboard (sing-box config format)**
- Or **Program → From file → sing-box JSON**

### Headless / systemd (Linux)

```bash
sudo sing-box run -c /path/to/sing-box-client-master.txt
```

### Validate before importing

```bash
sing-box check -c /tmp/master.json
```

### Clash mode toggle

| Mode | Behavior |
|---|---|
| Direct Mode | Everything goes direct |
| Global Mode | Everything through `proxy` selector |
| Smart Mode | CN direct, foreign via proxy, Meta/FB via facebook-proxy |

Access the Clash dashboard via `http://127.0.0.1:9090` (SSH tunnel if remote).

---

## 11. Troubleshooting

### `sing-box check FAILED`

The script prints the full error inline. Common cases:
- `legacy tun address fields is deprecated` — delete `/etc/singbox/sing-box-client-master.txt` and re-run an install.
- `legacy special outbounds is deprecated` — informational warning for `dns-out`/`block` types; not fatal in 1.11.

### Service starts but no connections work

```bash
sudo bash singbox-installer.sh doctor
```

Check: systemd unit pointing at managed config, kernel listeners present, cloud provider firewall open.

### "Port X is already in use"

- Server inbound listed → use a different port or `remove` the old tag first.
- Kernel listener → stop the other process or pick a different port.
- TCP and UDP on the same port don't conflict.

### Client connects but traffic shows 0 bytes

```bash
sudo ss -tnp | grep <SERVER_IP>
sudo ss -unp | grep <SERVER_IP>
```

If sockets exist but no data flows:
- Check fakeip is enabled in the client config
- Check both `sniff: true` on the inbound AND `{ action: "sniff" }` route rule exist
- TUN MTU: try lowering from 9000 to 1500

### Reality handshake failures

- Verify SNI is reachable from the server: `curl -v https://www.icloud.com:443 --connect-timeout 5`
- SNI must support TLS 1.3 + h2
- If intermittently unreachable, rotate: `regen-sni`

### `regen-uuid` / `regen-sni` says "tag not found"

Tag must match exactly: `vless-reality-443`, not `vless-reality_443`. Check with:
```bash
sudo bash singbox-installer.sh list
```

### Service won't start — credential errors

```bash
ls -la /etc/singbox/.state/
cat /etc/singbox/.state/reality.keypair
```

Fix corrupted state:
```bash
sudo bash singbox-installer.sh remove vless-reality-443
sudo bash singbox-installer.sh install vless-reality 443
```

### Installer log

```bash
less /tmp/singbox-installer.log
```

### Foreign sing-box config detected

Two configs from different installers. Options:

```bash
# Option A — archive the foreign, keep managed
sudo systemctl stop sing-box
sudo mv /etc/sing-box/config.json /etc/sing-box/config.json.foreign-bak
sudo bash singbox-installer.sh service start

# Option B — wipe both and start fresh
sudo systemctl stop sing-box
sudo rm /etc/sing-box/config.json /usr/local/etc/sing-box/config.json
sudo rm /etc/systemd/system/sing-box.service
sudo systemctl daemon-reload
sudo bash singbox-installer.sh install vless-reality 443
```

---

## 12. Migration from older script versions

### `.json` → `.txt` (v4/v5 master file)

```bash
sudo mv /etc/singbox/sing-box-client-master.json /etc/singbox/sing-box-client-master.txt
# or remove to bootstrap fresh:
sudo rm /etc/singbox/sing-box-client-master.json
```

### Orphan inbounds

```bash
sudo bash singbox-installer.sh list
sudo bash singbox-installer.sh remove <orphan-tag>
```

### Legacy TUN address fields

If the master client has `inet4_address` / `inet6_address` (pre-1.10 schema), v6 auto-migrates on the first install or remove with a `[WARN]` message and a `.legacy-bak-<timestamp>` backup.

---

## 13. Security notes

### Self-signed certs

Used for hy2/trojan/vmess inbounds with `insecure: true` on clients. TLS still encrypts traffic; authentication is via the protocol-level credential. DPI can fingerprint the self-signed cert's CN — swap in a Let's Encrypt cert if needed.

### Reality is the most secure option

Reality forges the real cert chain of the SNI target — to DPI active probing, traffic appears to be `www.icloud.com`. This is why vless-reality is the recommended primary protocol.

### Credentials hygiene

- Run `regen-uuid <tag>` quarterly minimum.
- Do **not** check the state directory or client configs into git.
- Per-install client configs contain working credentials — treat like SSH private keys.
- The Reality private key in `/etc/singbox/.state/reality.keypair` is shared across all Reality inbounds. Compromise of one leaks all.

### Limitations

- Compromised root account → everything is compromised.
- Leaked client config → no revocation primitive; rotate credentials to invalidate.
- DPI advances — SNI and credential rotation are countermeasures, not guarantees.

---

## 14. FAQ

**Q: Can I run multiple sing-box services on one box?**  
A: Not with this script. The systemd unit is fixed to `sing-box.service` pointing at one config. Multiple inbounds in one config achieves the same result with less complexity.

**Q: Can I edit the master client config by hand?**  
A: Yes. The next `install` / `remove` / `regen-*` will rewrite outbounds and selector lists. DNS rules, route rules, rule_set, and experimental sections are not touched by upserts.

**Q: How do I add a custom routing rule?**  
A: Edit `/etc/singbox/sing-box-client-master.txt`. Add your rule into `.route.rules` *before* the geoip-cn / geosite-cn rules (top-to-bottom match). Validate with `sing-box check -c /etc/singbox/sing-box-client-master.txt`.

**Q: Can I share the master client config with multiple users?**  
A: Yes, but all users share the same UUID/password. For per-user revocation you'd need a subscription backend — out of scope for this script.

**Q: Will this work on IPv6-only servers?**  
A: The `detect_public_ip` step uses IPv4 endpoints. IPv6-only servers require manual modification.

**Q: Why pin to 1.11.0?**  
A: It's the version the configs were written and tested for. To upgrade: replace the tarball, update `PINNED_VERSION` in the script, re-run an install.

**Q: How do I check what's running right now?**  
A:
```bash
sudo bash singbox-installer.sh doctor
sudo bash singbox-installer.sh list
sudo journalctl -u sing-box -n 50 --no-pager
sudo ss -tlnp | grep sing-box
sudo ss -ulnp | grep sing-box
```

**Q: Does this work behind NAT?**  
A: No — clients need to reach the server's public IP directly. NAT requires port forwarding.

**Q: What's the difference between master and a single per-install config?**  
A: If you only have one inbound, they're functionally similar. The master's value is automatic failover — adding more inbounds later updates the urltest without touching the client config on your devices.

**Q: Can I customize the urltest interval / target?**  
A: Edit the `auto` urltest outbound in `/etc/singbox/sing-box-client-master.txt`. Default: 3 minutes against `http://www.gstatic.com/generate_204`.
