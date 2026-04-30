# singbox-installer.sh — Documentation

A single-script sing-box 1.11.0 multi-protocol installer and manager. Designed for running on a Linux VPS to spin up one or more proxy inbounds (vless-reality, vmess-ws, trojan-ws, hysteria, hysteria2, shadowsocks) with automatic generation of both a master client config and per-install standalone client configs.

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
Tested on Ubuntu 22.04 / 24.04 and Debian 12. Should work on any Debian-family distro with `apt`. RHEL/Alma will need the apt-related sections adapted.

### Required on first run
The script auto-installs these via `apt`:
- `curl`, `wget`, `tar` — fetch and unpack things
- `jq` — JSON manipulation (used heavily)
- `uuid-runtime` — for fallback UUID generation
- `openssl` — self-signed cert + secret generation
- `iproute2` — for `ss` (port checks)
- `xxd` — for random WS path generation

### Required by you, ahead of time
- **Root access** on the server (the script runs `sudo` internally; just run it as root).
- **The pinned sing-box tarball** at `/root/singbox_installer/sing-box-1.11.0-linux-amd64.tar.gz`.
  This is intentional: pinning to a known version avoids surprises if upstream changes the schema again.

  **The script will auto-download this if missing**, fetching from `https://github.com/SagerNet/sing-box/releases/download/v1.11.0/` and verifying SHA256 against the matching `.sha256` checksum file from the same release. So strictly speaking you don't have to download it ahead of time — but if your server has restricted outbound access to GitHub, do it manually:
  ```bash
  mkdir -p /root/singbox_installer
  cd /root/singbox_installer
  wget https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz
  ```

  To use a mirror instead of GitHub, set the env var:
  ```bash
  SINGBOX_RELEASE_URL=https://your-mirror.example.com/sing-box/v1.11.0 \
      sudo -E bash singbox-installer.sh install vless-reality 443
  ```

  To enforce a specific SHA256 (skips the upstream `.sha256` file fetch):
  ```bash
  SINGBOX_SHA256=<expected-hex> \
      sudo -E bash singbox-installer.sh install vless-reality 443
  ```
- **A public IPv4** detectable from one of: `api.ipify.org`, `v4.ident.me`, `checkip.amazonaws.com`. The script tries each.
- **Open firewall** on the ports you'll use. The script attempts to auto-open via `ufw` / `iptables` / `firewalld`. If you're behind a cloud provider's external firewall (DigitalOcean, AWS, Hetzner Cloud, etc.), open the ports there too — the script can't do that for you.

---

## 2. Initial setup

The simplest path:

```bash
# 1. Place the script
mkdir -p /root/singbox_installer
cd /root/singbox_installer
# (copy singbox-installer.sh here)
chmod +x singbox-installer.sh

# 2. First install — the script will auto-download the sing-box tarball
#    from GitHub releases if it's not already at /root/singbox_installer/.
sudo bash singbox-installer.sh install vless-reality 443
```

If your server blocks GitHub outbound, do step 2 in two parts:

```bash
# 2a. Pre-download the tarball
cd /root/singbox_installer
wget https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz

# 2b. Install (skips download since tarball is already there)
sudo bash singbox-installer.sh install vless-reality 443
```

That's it. The first run does everything: installs deps, extracts sing-box to `/usr/local/bin/sing-box`, generates a Reality keypair, picks an SNI, builds the server config, builds the master client config, builds a per-install client config, installs the systemd unit, opens the firewall, and starts the service.

Subsequent installs reuse the existing setup and just append a new inbound.

---

## 3. Subcommand reference

All commands take the form `sudo bash singbox-installer.sh <SUBCOMMAND> [args]`.

### `install <PROTOCOL> <PORT> [--sni DOMAIN]`

Install or upsert a single inbound. The tag is auto-derived as `<protocol>-<port>` (e.g. `vless-reality-443`).

- **PROTOCOL** — one of: `vless-reality`, `vmess-ws`, `trojan-ws`, `hysteria`, `hysteria2`, `shadowsocks`
- **PORT** — 1–65535
- **--sni DOMAIN** — only meaningful for `vless-reality`; forces a specific Reality SNI camouflage target. Ignored with a warning for other protocols.

Same `<protocol> <port>` re-run = idempotent upsert. Server config gets the same inbound replaced in place; client configs get the outbound updated.

### `remove <TAG>`

Cleanly remove an inbound by its tag (e.g. `vless-reality-443`). Removes:
- The inbound from the server config
- The corresponding outbound from the master client config
- All references to the tag in selectors and urltests
- The per-install client config file
- All per-port secret files (UUID, password, ss2022-key, sni override, ws path)

After removal, the service is restarted automatically.

### `list`

Show three sections:
- All server inbounds (tag, type, port)
- The master client `proxy` selector contents
- All per-install client config files on disk

### `show <TAG>`

Print the contents of `/etc/singbox/sing-box-client-<TAG>.txt` to stdout. Useful for piping to a file or copying to another machine:

```bash
sudo bash singbox-installer.sh show vless-reality-443 > /tmp/jp1-only.json
scp /tmp/jp1-only.json me@laptop:~/
```

### `show-master`

Print the contents of `/etc/singbox/sing-box-client-master.txt` to stdout. This is the multi-node config with all your inbounds wired together via urltest.

### `regen-uuid <TAG>`

Rotate credentials for an inbound. Despite the name, this rotates the appropriate secret based on the protocol:

| Protocol | What gets rotated |
|---|---|
| vless-reality | UUID |
| vmess-ws | UUID |
| trojan-ws | password |
| hysteria | password (auth_str) |
| hysteria2 | password |
| shadowsocks | 2022-blake3-aes-256-gcm key |

After rotation: server inbound is re-upserted, master client outbound is re-upserted, per-install client file is rewritten, service is restarted. Old credentials are no longer valid; clients using them will need the new config.

### `regen-sni <TAG> [--sni DOMAIN]`

Reassign the Reality SNI for a `vless-reality` inbound. Only valid for type=vless inbounds. If `--sni` is omitted, picks a fresh one from the SNI pool that's not currently in use elsewhere on this host.

Use this when you suspect GFW is starting to pattern-match your current SNI's traffic.

### `set-sni-pool <DOMAIN1,DOMAIN2,DOMAIN3,...>`

Override the default SNI pool for this host. Comma-separated, no spaces. Saved to `/etc/singbox/.state/sni-pool.txt`. Used for all future Reality installs and for `regen-sni` when no override is given.

```bash
sudo bash singbox-installer.sh set-sni-pool www.icloud.com,www.bing.com,dl.google.com
```

### `show-sni-pool`

Print the active SNI pool — either the custom file at `/etc/singbox/.state/sni-pool.txt` or the built-in default.

### `doctor`

Health check. Reports:
- sing-box binary version
- Server config + master client paths and their existence
- Whether a "foreign" sing-box config exists at `/etc/sing-box/config.json` (a common path used by other installers — flagged so you don't get path-collision surprises)
- systemd unit `ExecStart` and whether it points at the managed config
- Service active/inactive
- Active TCP/UDP listeners belonging to sing-box
- `sing-box check` validation for both server and master configs
- Active SNI pool

### `service <action>`

Wrapper around `systemctl` for sing-box:
- `start` / `stop` / `restart` — equivalent to `systemctl <action> sing-box`
- `status` — first 20 lines of `systemctl status`
- `logs` — equivalent to `journalctl -u sing-box -f`

### `help`

Print usage. Same as no args or `-h`/`--help`.

### Backwards-compat shorthand

`<PROTOCOL> <PORT>` alone is treated as `install <PROTOCOL> <PORT>`. So:

```bash
sudo bash singbox-installer.sh vless-reality 443
# is equivalent to
sudo bash singbox-installer.sh install vless-reality 443
```

---

## 4. Output files explained

After installation you'll have:

| Path | Purpose |
|---|---|
| `/usr/local/etc/sing-box/config.json` | **Server config**. The systemd unit runs `sing-box run -c` against this. Contains the inbounds for all your installed protocols. |
| `/etc/singbox/sing-box-client-master.txt` | **Master client config**. All inbounds-as-outbounds wired into a urltest (`auto`) and selector (`proxy`). Use this on a phone or desktop client to get automatic failover between all your nodes. |
| `/etc/singbox/sing-box-client-<protocol>-<port>.txt` | **Per-install client config**. Standalone single-node config. Useful for testing one protocol in isolation, or for handing to one user who only needs one of your nodes. |
| `/etc/systemd/system/sing-box.service` | systemd unit. Restart-on-failure, capabilities for binding privileged ports and managing routes. |
| `/etc/singbox/.state/` | Persistent state — Reality keypair, self-signed cert, per-port secrets, SNI overrides. **Do not delete unless you want to regenerate everything.** |
| `/tmp/singbox-installer.log` | Installer log. Truncated at the start of every install. Includes full sing-box check output. |
| `/tmp/singbox.log` | Runtime log from sing-box itself (set in the server config's log block). |

### Master vs per-install: when to use which

**Master** is what you ship to anyone using your server seriously. It has all nodes, urltest, multiple selectors, full Clash mode support (Direct / Global / Smart), the FB-proxy selector for separately routing Meta apps, ad-blocking, geoip-cn smart routing, and the clash_api endpoint at `127.0.0.1:9090` for in-app stats.

**Per-install** is for testing or handoff scenarios:
- "Does my hysteria2 inbound work in isolation?" → use `sing-box-client-hysteria2-443.txt`
- "Give a friend access to just the Tokyo VPS" → hand them `sing-box-client-vless-reality-443.txt`
- "Verify the Reality SNI is reachable" → run the per-install file locally with `sing-box run -c <file>`

The per-install files have the same DNS/routing structure as the master, just with a single outbound. The `facebook-proxy` selector is collapsed into `proxy` so FB routing still works on one node.

---

## 5. Common workflows

### Install a primary VLESS Reality + a hysteria2 fallback

```bash
sudo bash singbox-installer.sh install vless-reality 443
sudo bash singbox-installer.sh install hysteria2 443    # OK — UDP, different transport from TCP/443
```

The master client will now have `proxy` (selector) → `auto` (urltest) → both nodes. The urltest probes both every 3 minutes and routes through whichever is faster.

### Install three Reality inbounds with different SNIs

Done one at a time, each gets a different SNI from the pool:

```bash
sudo bash singbox-installer.sh install vless-reality 443
sudo bash singbox-installer.sh install vless-reality 8443
sudo bash singbox-installer.sh install vless-reality 2053
sudo bash singbox-installer.sh list
```

Or force a specific SNI per install:

```bash
sudo bash singbox-installer.sh install vless-reality 443 --sni www.icloud.com
sudo bash singbox-installer.sh install vless-reality 8443 --sni www.bing.com
sudo bash singbox-installer.sh install vless-reality 2053 --sni dl.google.com
```

### Customize the SNI pool, then install

```bash
sudo bash singbox-installer.sh set-sni-pool www.icloud.com,www.bing.com,dl.google.com,addons.mozilla.org
sudo bash singbox-installer.sh install vless-reality 443
```

Each future install will draw from this list.

### Rotate credentials quarterly

```bash
sudo bash singbox-installer.sh regen-uuid vless-reality-443
sudo bash singbox-installer.sh regen-uuid hysteria2-443
sudo bash singbox-installer.sh regen-sni  vless-reality-443
```

After rotation, fetch the updated client configs and redistribute:

```bash
sudo bash singbox-installer.sh show-master > /tmp/master-$(date +%F).json
```

### Decommission a node cleanly

```bash
sudo bash singbox-installer.sh remove vless-reality-2053
```

This removes from server config, master client, all selectors, and deletes secrets. Anyone whose client config still references it will get connection failures on that node only — the urltest will route around it.

### Health check after an install

```bash
sudo bash singbox-installer.sh doctor
```

If anything looks wrong, paste the output when asking for help — it covers 90% of the diagnostic surface.

### Tail the live log during testing

```bash
sudo bash singbox-installer.sh service logs
```

Or directly: `sudo journalctl -u sing-box -f`

---

## 6. Protocol reference

| Protocol | Transport | Best for | Notes |
|---|---|---|---|
| `vless-reality` | TCP | Primary inbound; best stealth available | Forges TLS handshake to a real big-site SNI. Requires the camouflage target to be reachable from the server itself. |
| `hysteria2` | UDP | Fast residential ISPs; primary fallback | QUIC-based. Great throughput but UDP can be QoS-throttled by some carriers. |
| `trojan-ws` | TCP | CDN-fronting setups; rainy-day fallback | Self-signed cert + WS. To use behind Cloudflare, terminate TLS at nginx/CF and have CF point to the WS path. |
| `vmess-ws` | TCP | When client compatibility matters | Older protocol, still widely supported. Use sparingly — VLESS is strictly better on stealth. |
| `hysteria` | UDP | Legacy compatibility only | Hysteria v1, deprecated upstream. Script warns when you install it. Use only if a specific client mandates v1. |
| `shadowsocks` | TCP | Low-overhead bulk forwarding | Uses 2022-blake3-aes-256-gcm. No TLS, no metadata leakage protection — DPI can still pattern-match SS traffic. |

### What credentials you'll see per protocol

| Protocol | Server-side fields | Client connects with |
|---|---|---|
| vless-reality | UUID, Reality keypair, SNI, short_id | UUID, Reality public key, SNI, short_id |
| vmess-ws | UUID, WS path, self-signed cert | UUID, WS path, `insecure: true` |
| trojan-ws | password, WS path, self-signed cert | password, WS path, `insecure: true` |
| hysteria | password (auth_str), self-signed cert, up/down mbps | password, server_name `bing.com`, `insecure: true` |
| hysteria2 | password, self-signed cert | password, server_name `bing.com`, `insecure: true` |
| shadowsocks | 32-byte base64 key, method `2022-blake3-aes-256-gcm` | same key, same method |

The self-signed cert is shared across hysteria, hysteria2, vmess-ws, and trojan-ws — generated once at first install with CN=bing.com / SAN=bing.com,www.bing.com. The `insecure: true` flag on the client side is required because clients can't validate the self-signed chain. **Reality does not use self-signed certs** — it forges real handshakes to the SNI target's actual cert chain.

---

## 7. Port and transport rules

The port collision check is **transport-aware**. TCP and UDP listeners on the same port number are independent at the kernel level, so:

| Combination | Allowed? | Why |
|---|---|---|
| vless-reality TCP/443 + hysteria2 UDP/443 | ✅ | Different transports |
| vless-reality TCP/443 + trojan-ws TCP/443 | ❌ | Both TCP/443 |
| vless-reality TCP/443 + vless-reality TCP/443 | ✅ (idempotent) | Same tag — re-run upserts |
| vless-reality TCP/443 + nginx TCP/443 | ❌ | Kernel listener occupied by nginx |
| vless-reality TCP/443 + vless-reality TCP/8443 | ✅ | Different ports |

The check looks at three sources:
1. Existing inbounds in the server config
2. Kernel listeners via `ss -tlnp` / `ss -ulnp`
3. (Not yet) cloud provider firewall rules — that's still your job

If a real conflict is detected, the install refuses with a list of conflicting items and a suggestion to use a different port.

### What ports should I use?

For Reality on the primary inbound, **TCP/443**. GFW rarely blocks 443 entirely because too much real HTTPS uses it. Alternates I use as additional Reality ports: 8443, 2053, 2087, 2096, 2083 (all common HTTPS-alternate ports that some legitimate services use).

For hysteria2, **UDP/443** alongside Reality on TCP/443 is great — same number, different transport, no conflict. Alternates: 36500–36600 range, 8443/UDP.

Avoid:
- Ports below 1024 except 80/443 (some firewalls treat them suspiciously)
- Memorable test ports like 12345, 8888 (DPI looks at them more carefully)
- Ports that match common services (3389/RDP, 22/SSH) on the same IP

---

## 8. SNI management for vless-reality

Reality requires a real-world SNI to forge handshakes against. The script ships with a default pool:

```
www.icloud.com
gateway.icloud.com
www.bing.com
dl.google.com
addons.mozilla.org
www.microsoft.com
s0.awsstatic.com
```

These are chosen for:
- TLS 1.3 + h2/h3 support (Reality requires it)
- Big enough that DPI cannot block without breaking real services
- Reachable from inside CN (the target is probed by your server during handshake)
- NOT served from Cloudflare (CF cert chains have known fingerprints)

### How SNIs get assigned to ports

When you `install vless-reality <port>`:
1. If `--sni <DOMAIN>` is given, that's used.
2. Otherwise, look up the saved SNI for this port at `/etc/singbox/.state/sni-<port>.txt` (idempotency — re-installing on 443 always picks the same SNI).
3. Otherwise, scan the SNI pool for a domain not already used by another inbound on this host, and pick the first unused one.
4. If the pool is exhausted, fall back to deterministic-by-port (`pool[port % len(pool)]`).

This means installing on 443 first, then 8443, then 2053 will give each a different SNI automatically.

### When to rotate SNIs

Three reasons:
1. **Confirmed pattern-matching by GFW.** If one of your nodes consistently gets blocked while others using different SNIs from the same server are fine, rotate.
2. **Public crackdown periods.** Around CCP plenums, October 1, Spring Festival, etc., GFW gets more aggressive. Pre-emptively rotating SNIs can help.
3. **Quarterly hygiene.** Same logic as rotating UUIDs.

```bash
sudo bash singbox-installer.sh regen-sni vless-reality-443                   # auto-pick fresh
sudo bash singbox-installer.sh regen-sni vless-reality-443 --sni www.bing.com  # specific
```

### Adding domains to the pool

```bash
sudo bash singbox-installer.sh set-sni-pool $(cat <<EOF | tr '\n' ',' | sed 's/,$//'
www.icloud.com
www.bing.com
dl.google.com
addons.mozilla.org
www.cloudflare.com
www.python.org
www.kernel.org
EOF
)
```

(The last three are riskier — `www.cloudflare.com` puts you behind a known CF cert chain, `python.org` and `kernel.org` are smaller-traffic sites that DPI can fingerprint more easily. Stick to the defaults unless you have a reason to expand.)

---

## 9. State directory and credential lifecycle

The `/etc/singbox/.state/` directory is the persistent secret store. Files there:

| File | Contents | Created when |
|---|---|---|
| `reality.keypair` | Reality private + public key (text) | First vless-reality install |
| `self-signed.crt` / `self-signed.key` | Self-signed TLS cert (PEM) | First hy2/trojan/vmess install |
| `uuid-<port>.secret` | UUID for vless/vmess on this port | install / regen-uuid |
| `password-<port>.secret` | Password for trojan/hy/hy2 on this port | install / regen-uuid |
| `ss2022-key-<port>.secret` | 32-byte base64 key for shadowsocks | install / regen-uuid |
| `sni-<port>.txt` | Reality SNI assigned to this port | install / regen-sni |
| `trojan-<port>.path` / `vmess-<port>.path` | Random hex WS path | install |
| `sni-pool.txt` | Custom SNI pool override (one domain per line) | set-sni-pool |

### Why this matters for idempotency

Re-running `install vless-reality 443` does NOT generate a new UUID. It looks up `/etc/singbox/.state/uuid-443.secret` and reuses the same value. Same for the SNI. This means:
- Re-running an install after a partial failure is safe — clients with the old UUID still work.
- To actually rotate credentials, use `regen-uuid` / `regen-sni`.
- `remove <tag>` deletes the secret files for that port. The next `install` on that port will generate fresh ones.

### Backing up the state directory

If you're going to migrate the server or rebuild, this is the only thing worth backing up:

```bash
tar czf /root/singbox-state-backup-$(date +%F).tar.gz \
    /etc/singbox/.state/ \
    /etc/singbox/sing-box-client-master.txt \
    /usr/local/etc/sing-box/config.json
```

Restore by extracting at `/`. After restore, run the installer once with any existing tag to verify everything's wired up — it'll be a no-op idempotent retry.

---

## 10. Importing client configs into apps

### sing-box for Android (SFA)

1. **Profiles → New profile → Type: Local**
2. Either paste the JSON from `show-master` / `show <tag>`, or import a file you've copied to the device
3. Save
4. Tap the profile to switch to it
5. Toggle "Start" at the top of the main screen

### sing-box for iOS / macOS

Same flow as Android. The macOS app is a Mac Catalyst port, so the menus are identical.

### NekoBox / NekoRay (desktop)

NekoBox supports importing sing-box JSON directly:
- **Program → From clipboard (sing-box config format)** after copying the JSON
- Or **Program → From file → sing-box JSON**

### Headless desktop usage

```bash
sudo sing-box run -c /path/to/sing-box-client-master.txt
```

For systemd-managed desktop usage (Linux), create a unit file mirroring the server unit but pointing at the client config.

### Validating before importing

Always validate before pushing to a phone:

```bash
sing-box check -c /tmp/master.json
```

If `sing-box check` complains, the app will fail to start the profile with a less-helpful error. Fix on the server first.

### Configuring the in-app mode toggle

The master config sets `clash_api.default_mode` to `Smart Mode`. Once connected, the app's mode picker offers:

| Mode | Behavior |
|---|---|
| Direct Mode | Everything goes direct (proxy disabled) |
| Global Mode | Everything goes through `proxy` selector |
| Smart Mode | Uses your route.rules: CN domains/IPs direct, foreign through proxy, FB through facebook-proxy |

You can also point a Clash dashboard (YACD, Zashboard) at `http://<phone-or-tunnel>:9090` to see live traffic, latency probes, and node health. By default `clash_api` only listens on `127.0.0.1:9090`, so you'd need an SSH tunnel to access from your laptop.

---

## 11. Troubleshooting

### "sing-box check FAILED"

The script's `singbox_check_loud` helper prints the full sing-box error inline. Copy the indented `│ ...` block and address whatever specific field it complains about. Common cases:

- `legacy tun address fields is deprecated` — you're running with an old client manifest from a pre-1.10 installer. The script should auto-migrate; if not, delete `/etc/singbox/sing-box-client-master.txt` and re-run an install to regenerate.
- `legacy special outbounds is deprecated` — informational warning about `dns-out` / `block` outbound types in legacy configs. Not fatal in 1.11; will fail in 1.13.

### Service starts but no connections work

Run the doctor:

```bash
sudo bash singbox-installer.sh doctor
```

Check:
- Is the **systemd unit pointing at the managed config?** If not, you have a foreign installer's unit hijacking the path.
- Are the **kernel listeners** present? If `ss` shows nothing, sing-box might have started but failed to bind (port permission, port in use by something the script didn't detect).
- Is the **cloud-provider firewall** open for the port and transport? The script handles ufw/iptables/firewalld on the VM but not external firewalls (DigitalOcean Cloud Firewall, AWS Security Groups, GCP firewall rules, etc.).

### "Port X is already in use"

The collision check found a conflict. Read the listed conflicts:
- Server inbound listed → there's already a sing-box inbound on that port+transport. Pick a different port, or `remove` the old tag first if you want to replace it.
- Kernel listener `users:(("nginx",pid=...))` → another process holds that port. Stop the other process or pick a different port.

Remember: TCP and UDP on the same port number don't conflict, so installing `vless-reality 443` and `hysteria2 443` together is fine.

### Client connects but traffic shows 0 bytes / no response

This usually means routing is matching everything to direct. Check on the client:

```bash
# Are you actually connected to your server?
sudo ss -tnp | grep <SERVER_IP>     # should show TCP for vless/trojan
sudo ss -unp | grep <SERVER_IP>     # should show UDP for hy2
```

If sockets exist but data isn't flowing, the issue is either:
- DNS not being routed through the proxy (check fakeip is enabled in the client config)
- Sniff misconfiguration (the master config has both inbound-level `sniff: true` AND a route rule `{ action: "sniff" }` — keep both)
- TUN MTU issue — try lowering from 9000 to 1500 if you're getting packet fragmentation errors

### Reality handshake failures

If the client logs show TLS handshake errors specifically against the SNI target:
- Verify the SNI is actually reachable **from the server**: `curl -v https://www.icloud.com:443 --connect-timeout 5`. Reality probes this during the handshake.
- The SNI must support TLS 1.3 + h2 (or h3). `dl.google.com` does, `static.example.com` probably doesn't.
- If the SNI is intermittently unreachable from your server's region, pick a different one with `regen-sni`.

### The `regen-uuid` / `regen-sni` commands say "tag not found"

The tag must match exactly — `vless-reality-443`, not `vless-reality_443` or `vless-443`. List the actual tags first:

```bash
sudo bash singbox-installer.sh list
```

### Service won't start, journal shows credential errors

Probably means the state directory got corrupted (e.g. truncated `.secret` files). Verify:

```bash
ls -la /etc/singbox/.state/
cat /etc/singbox/.state/reality.keypair
```

If anything looks wrong, the safe fix is:

```bash
# Remove the broken inbound (this also removes its secrets)
sudo bash singbox-installer.sh remove vless-reality-443

# Re-install — fresh secrets
sudo bash singbox-installer.sh install vless-reality 443
```

Existing clients with the old UUID will fail and need the new config.

### How to read the install log

```bash
less /tmp/singbox-installer.log
```

The full sing-box check output, jq errors, and apt output all land here. If the script exits abnormally, this is where to look.

### Foreign sing-box config detected

If `doctor` reports a "foreign" config at `/etc/sing-box/config.json` while this installer manages `/usr/local/etc/sing-box/config.json`, you have two configs on the box from different installers. Resolve by:

```bash
# Option A — adopt the foreign config (advanced; not auto-supported)
# Manually merge any inbounds from the foreign config into the managed one,
# then archive the foreign:
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

If you've been running v1–v5 of this installer (or another installer), the v6 script handles most migrations automatically. The two manual steps:

### If you have `/etc/singbox/sing-box-client-master.json` (v4/v5 extension)

v6 uses `.txt`. Either rename or remove:

```bash
sudo mv /etc/singbox/sing-box-client-master.json /etc/singbox/sing-box-client-master.txt
# OR — start fresh (recommended if you're not sure)
sudo rm /etc/singbox/sing-box-client-master.json
```

If you remove it, the next install will bootstrap a fresh master with the full networklinkpro structure.

### If you have orphan inbounds from earlier test runs

You probably have inbounds in the server config that aren't in the master client (because client/server got out of sync during earlier failures). Clean them:

```bash
sudo bash singbox-installer.sh list

# For each tag in the server config that isn't in the master 'proxy' selector:
sudo bash singbox-installer.sh remove <orphan-tag>
```

### Legacy TUN address fields

If a master client has `inet4_address` / `inet6_address` (pre-1.10 schema), v6 auto-migrates on the first install or remove. You'll see a `[WARN] Client manifest uses legacy TUN fields — migrating to 1.11 schema` and a `.legacy-bak-<timestamp>` backup.

---

## 13. Security notes

### Self-signed certs vs Let's Encrypt

The script generates a self-signed cert for hy2/trojan/vmess inbounds, and clients use `insecure: true` to skip validation. This is fine for personal/small-team use because:
- The TLS layer still encrypts traffic (no plaintext exposure)
- Authentication is via the protocol-level password/UUID, not the cert

Limitations:
- DPI can fingerprint the self-signed cert's CN/SAN. If GFW starts pattern-matching, swap in a real Let's Encrypt cert and remove `insecure: true` on the client. The script doesn't automate that today.
- If you put the inbound behind Cloudflare (orange-cloud), Cloudflare terminates TLS for you and the cert at your origin doesn't matter. This is the "trojan-ws via CDN" pattern from earlier in this thread.

### Reality is the most secure option

Reality doesn't use a self-signed cert at all — it forges the real cert chain of the SNI target. To DPI active probing, you really do appear to be `www.icloud.com`. This is why the script defaults to vless-reality as the primary protocol.

### Credentials hygiene

- Run `regen-uuid <tag>` quarterly minimum, more frequently if you suspect a leak.
- Do **not** check the state directory or client configs into git.
- Per-install client configs (`sing-box-client-<tag>.txt`) contain working credentials — treat them like SSH private keys.
- The Reality private key in `/etc/singbox/.state/reality.keypair` is shared across all Reality inbounds on the server. Compromise of one leaks all.

### What the script does NOT protect against

- A compromised root account. The script runs as root, so root-level access on the server compromises everything.
- A leaked client config file. No revocation primitive — to revoke, rotate the credentials.
- An attacker on the same network as the client. The proxy hides traffic from the user's local ISP, but doesn't help if the attacker is on the user's LAN with a malicious DNS server.
- DPI advances. SNI rotation and credential rotation are countermeasures, but the cat-and-mouse game continues.

---

## 14. FAQ

**Q: Can I run multiple sing-box services on one box?**
A: Not with this script. The systemd unit is fixed at `sing-box.service` pointing at one config. If you need that, run a second binary at a different path with a different unit. But before doing that, ask why — multiple inbounds in one config does the same thing with less complexity.

**Q: Can I edit the master client config by hand?**
A: Yes, but the next `install` / `remove` / `regen-*` will rewrite the parts it manages (outbounds and selector lists). The DNS rules, route rules, rule_set, experimental sections aren't touched by upserts, so customizations there are safe.

**Q: How do I add a custom routing rule to the master client?**
A: Edit `/etc/singbox/sing-box-client-master.txt` directly. Add your rule into `.route.rules` *before* the geoip-cn / geosite-cn rules (rules are matched top-to-bottom). Validate with `sing-box check -c /etc/singbox/sing-box-client-master.txt`.

**Q: Can I share the master client config with multiple users?**
A: Yes, but they all use the same UUID/password — there's no per-user revocation. For that you'd need a backend that issues per-user manifests on a subscription URL (out of scope for this script).

**Q: Will this work on IPv6-only servers?**
A: The detect_public_ip step uses IPv4 endpoints. You'd need to modify it to detect IPv6 and emit `[v6]:port` syntax in client configs. Not supported out-of-the-box.

**Q: Why pin to 1.11.0 specifically?**
A: That's the version we tested against and the schema we wrote for. 1.12 will remove the legacy TUN address support entirely (we already migrated). 1.13 will remove the legacy `dns-out`/`block` outbound types (script avoids them). When you're ready to move to a newer version, replace the tarball, update `PINNED_VERSION` near the top of the script, and re-run an install — the script will validate against the new binary.

**Q: How do I check what's actually running right now?**
A:
```bash
sudo bash singbox-installer.sh doctor
sudo bash singbox-installer.sh list
sudo journalctl -u sing-box -n 50 --no-pager
sudo ss -tlnp | grep sing-box
sudo ss -ulnp | grep sing-box
```

**Q: Does this work behind a NAT?**
A: For inbound proxy traffic, no — clients need to connect to the server's public IP/port. NAT requires port forwarding from the public IP to the VPS. If you're on a typical cloud VPS this isn't an issue (each VPS has its own public IP).

**Q: Can I use this with a VPS that has a domain pointed at it?**
A: Yes. The script defaults to using the public IPv4 in client configs, but you can manually edit any `sing-box-client-*.txt` file to replace the IP with your domain. Then the client connects via DNS, which is more flexible (you can change the A record without re-distributing configs).

**Q: What's the difference between the "master" and just installing vless-reality alone?**
A: The master is a multi-node config. If you only ever install one inbound, the master and the single per-install client are functionally similar (one outbound either way). The benefit of using the master is that when you add a second/third inbound later, the master automatically gets the new node added to its urltest — your client config stays the same on disk but now has failover.

**Q: Can I customize the urltest interval / target?**
A: Edit `/etc/singbox/sing-box-client-master.txt` directly. Find the `auto` urltest outbound and change `interval` or `url`. The current default is 3 minutes against `http://www.gstatic.com/generate_204` (the standard captive-portal probe).
