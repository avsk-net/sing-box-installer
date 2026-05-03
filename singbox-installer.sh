#!/bin/bash

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF_DIR="/usr/local/etc/sing-box"
SINGBOX_CONF="$SINGBOX_CONF_DIR/config.json"
SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"

CLIENT_DIR="/etc/singbox"
CLIENT_MASTER="$CLIENT_DIR/sing-box-client-master.txt"

STATE_DIR="$CLIENT_DIR/.state"
SNI_POOL_FILE="$STATE_DIR/sni-pool.txt"
REALITY_KEY_FILE="$STATE_DIR/reality.keypair"
SS_CRT="$STATE_DIR/self-signed.crt"
SS_KEY="$STATE_DIR/self-signed.key"

LOG_FILE="/tmp/singbox-installer.log"

PINNED_VERSION="1.11.0"
BUNDLED_TARBALL="/root/singbox_installer/sing-box-${PINNED_VERSION}-linux-amd64.tar.gz"
EXTRACTED_SUBDIR="sing-box-${PINNED_VERSION}-linux-amd64"

SINGBOX_RELEASE_URL="${SINGBOX_RELEASE_URL:-https://github.com/SagerNet/sing-box/releases/download/v$PINNED_VERSION}"

DEFAULT_SNI_POOL=(
    "www.icloud.com"
    "gateway.icloud.com"
    "www.bing.com"
    "dl.google.com"
    "addons.mozilla.org"
    "www.microsoft.com"
    "s0.awsstatic.com"
)

SHORT_ID="a1b2c3d4"

info()   { echo -e "${CYAN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
err()    { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
die()    { err "$*"; exit 1; }
banner() { echo -e "${BOLD}${GREEN}$*${NC}"; }
indent() { if [[ -z "${1:-}" ]]; then echo "    (empty)"; else echo "$1" | sed 's/^/    │ /'; fi; }

singbox_check_loud() {
    local cfg="$1" label="$2"
    info "Validating $label..."
    local out rc
    out=$("$SINGBOX_BIN" check -c "$cfg" 2>&1); rc=$?
    if (( rc != 0 )); then
        err "sing-box check FAILED ($label, exit $rc):"
        indent "$out"
        return 1
    fi
    if echo "$out" | grep -qE "^(WARN|ERROR|FATAL)"; then
        warn "$label valid but emits diagnostics:"
        indent "$(echo "$out" | grep -E '^(WARN|ERROR|FATAL)')"
    fi
    ok "$label valid"
    return 0
}

usage() {
cat <<EOF
${BOLD}singbox-installer.sh${NC} — sing-box 1.11.0 multi-protocol installer

${BOLD}Subcommands:${NC}
  install <PROTOCOL> <PORT> [--sni DOMAIN]
  remove  <TAG>                  remove an inbound + its client outbound
  list                           list installed inbounds + client outbounds
  show <TAG>                     print the standalone client file for one tag
  show-master                    print the master client file (all nodes)
  regen-uuid <TAG>               rotate credentials for an inbound
  regen-sni  <TAG> [--sni D]     reassign SNI (vless-reality only)
  set-sni-pool d1,d2,d3,...      override default SNI pool for this host
  show-sni-pool
  doctor                         health check
  service <action>               start | stop | restart | status | logs

${BOLD}Protocols:${NC}
  vless-reality   TCP   VLESS + Vision + Reality (recommended primary)
  vmess-ws        TCP   VMess over WebSocket+TLS
  trojan-ws       TCP   Trojan over WebSocket+TLS
  hysteria        UDP   Hysteria v1 (legacy; consider hy2 instead)
  hysteria2       UDP   Hysteria v2 (QUIC)
  shadowsocks     TCP   Shadowsocks 2022 (2022-blake3-aes-256-gcm)

${BOLD}Output files:${NC}
  Server config       $SINGBOX_CONF
  Master client       $CLIENT_MASTER
  Per-install client  $CLIENT_DIR/sing-box-client-<protocol>-<port>.txt

${BOLD}Examples:${NC}
  sudo bash $0 install vless-reality 443
  sudo bash $0 install hysteria2     443      # OK alongside TCP/443
  sudo bash $0 install shadowsocks   8388
  sudo bash $0 list
  sudo bash $0 show vless-reality-443        # print just-this-node config
  sudo bash $0 show-master > my-phone.json   # whole fleet config
EOF
}

require_root() { [[ $EUID -ne 0 ]] && die "Run as root (sudo)."; }

ensure_hostname_in_hosts() {
    local h; h=$(hostname 2>/dev/null || echo "")
    if [[ -n "$h" ]] && ! grep -qE "^[0-9.:]+\s+.*\b${h}\b" /etc/hosts 2>/dev/null; then
        echo "127.0.1.1 $h" >> /etc/hosts
    fi
}

ensure_deps() {
    info "Ensuring dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>&1 | tee -a "$LOG_FILE" >/dev/null
    apt-get install -y -qq curl wget tar jq uuid-runtime openssl iproute2 xxd \
        2>&1 | tee -a "$LOG_FILE" >/dev/null
    ok "Dependencies ready"
}

ensure_singbox() {
    if [[ -f "$SINGBOX_BIN" ]]; then
        local cur; cur=$("$SINGBOX_BIN" version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
        if [[ "$cur" == 1.11.* ]]; then
            ok "sing-box v$cur ready"; return
        fi
        warn "Found v$cur; replacing with pinned v$PINNED_VERSION"
    fi

    if [[ ! -f "$BUNDLED_TARBALL" ]]; then
        warn "Bundled tarball not found at $BUNDLED_TARBALL"
        info "Downloading sing-box v$PINNED_VERSION from official GitHub release..."

        mkdir -p "$(dirname "$BUNDLED_TARBALL")"
        local tarball_url="$SINGBOX_RELEASE_URL/sing-box-${PINNED_VERSION}-linux-amd64.tar.gz"

        if ! curl -fsSL --max-time 120 -o "$BUNDLED_TARBALL" "$tarball_url" 2>>"$LOG_FILE"; then
            err "Download failed: $tarball_url"
            err "Check connectivity to github.com (or set SINGBOX_RELEASE_URL=<mirror>)"
            die "Cannot fetch sing-box tarball"
        fi
        ok "Downloaded: $BUNDLED_TARBALL"

        local computed
        computed=$(sha256sum "$BUNDLED_TARBALL" | awk '{print $1}')
        info "Computed SHA256: $computed"

        if [[ -n "${SINGBOX_SHA256:-}" ]]; then
            if [[ "$computed" != "$SINGBOX_SHA256" ]]; then
                rm -f "$BUNDLED_TARBALL"
                die "SHA256 mismatch! expected=$SINGBOX_SHA256 got=$computed"
            fi
            ok "SHA256 matches user-provided SINGBOX_SHA256 ✓"
        else
            local sums_url="$SINGBOX_RELEASE_URL/sing-box-${PINNED_VERSION}-linux-amd64.tar.gz.sha256"
            local sums_file; sums_file=$(mktemp)
            if curl -fsSL --max-time 30 -o "$sums_file" "$sums_url" 2>>"$LOG_FILE"; then
                local expected; expected=$(awk '{print $1}' "$sums_file" | head -1)
                rm -f "$sums_file"
                if [[ -n "$expected" && "$computed" == "$expected" ]]; then
                    ok "SHA256 verified against upstream .sha256 file ✓"
                elif [[ -n "$expected" ]]; then
                    rm -f "$BUNDLED_TARBALL"
                    die "SHA256 mismatch vs upstream! expected=$expected got=$computed"
                else
                    warn "Upstream .sha256 file empty/malformed — proceeding without verification"
                fi
            else
                rm -f "$sums_file"
                warn "Could not fetch upstream .sha256 from $sums_url"
                warn "Proceeding without SHA256 verification (set SINGBOX_SHA256=<hex> to enforce)"
            fi
        fi
    fi

    local tmp; tmp=$(mktemp -d)
    if ! tar -xzf "$BUNDLED_TARBALL" -C "$tmp" 2>>"$LOG_FILE"; then
        rm -rf "$tmp"
        die "extract failed (corrupted tarball? remove $BUNDLED_TARBALL and retry)"
    fi
    local bin="$tmp/${EXTRACTED_SUBDIR}/sing-box"
    [[ -f "$bin" ]] || { rm -rf "$tmp"; die "binary not in tarball"; }
    install -m 755 "$bin" "$SINGBOX_BIN"
    rm -rf "$tmp"
    ok "sing-box v$PINNED_VERSION installed"
}

detect_public_ip() {
    [[ -n "${PUBLIC_IP:-}" ]] && return
    info "Detecting public IPv4..."
    PUBLIC_IP=""
    for svc in "https://api.ipify.org" "https://v4.ident.me" "https://checkip.amazonaws.com"; do
        PUBLIC_IP=$(curl -s --max-time 6 "$svc" | tr -d '[:space:]') && [[ -n "$PUBLIC_IP" ]] && break
    done
    [[ -z "$PUBLIC_IP" ]] && die "Could not detect public IP."
    ok "Public IP: $PUBLIC_IP"
}

get_sni_pool() {
    if [[ -s "$SNI_POOL_FILE" ]]; then
        awk 'NF && $1 !~ /^#/' "$SNI_POOL_FILE"
    else
        printf '%s\n' "${DEFAULT_SNI_POOL[@]}"
    fi
}

pick_sni_for_port() {
    local port="$1"
    local pool=()
    while IFS= read -r d; do pool+=("$d"); done < <(get_sni_pool)
    local n="${#pool[@]}"
    (( n == 0 )) && die "SNI pool empty (set with: $0 set-sni-pool ...)"

    local used=()
    if [[ -f "$SINGBOX_CONF" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && used+=("$s")
        done < <(jq -r '.inbounds[]?.tls?.server_name // empty' "$SINGBOX_CONF" 2>/dev/null)
    fi

    for d in "${pool[@]}"; do
        local hit=0
        for u in "${used[@]:-}"; do [[ "$u" == "$d" ]] && hit=1 && break; done
        (( hit == 0 )) && { echo "$d"; return; }
    done
    echo "${pool[$(( port % n ))]}"
}

get_port_sni() {
    local port="$1"; local f="$STATE_DIR/sni-${port}.txt"
    [[ -s "$f" ]] && cat "$f" || echo ""
}
save_port_sni() {
    local port="$1" sni="$2"
    echo -n "$sni" > "$STATE_DIR/sni-${port}.txt"
    chmod 600 "$STATE_DIR/sni-${port}.txt"
}

gen_uuid()       { "$SINGBOX_BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
gen_password()   { openssl rand -base64 24 | tr -d '\n=' | tr '/+' 'ab'; }
gen_ss2022_key() { openssl rand -base64 32 | tr -d '\n'; }

ensure_self_signed_cert() {
    if [[ ! -s "$SS_CRT" || ! -s "$SS_KEY" ]]; then
        info "Generating self-signed cert (4096-bit, 10y)..."
        openssl req -x509 -nodes -newkey rsa:4096 \
            -keyout "$SS_KEY" -out "$SS_CRT" -days 3650 \
            -subj "/CN=bing.com" \
            -addext "subjectAltName=DNS:bing.com,DNS:www.bing.com" \
            >>"$LOG_FILE" 2>&1 || die "openssl failed"
        chmod 600 "$SS_KEY"
    fi
}

ensure_reality_keypair() {
    if [[ ! -s "$REALITY_KEY_FILE" ]]; then
        info "Generating Reality keypair..."
        local out; out=$("$SINGBOX_BIN" generate reality-keypair 2>&1)
        local rc=$?
        if (( rc != 0 )) || [[ -z "$out" ]]; then
            err "reality-keypair generation failed:"; indent "$out"
            die "Cannot generate Reality keypair."
        fi
        echo "$out" > "$REALITY_KEY_FILE"
        chmod 600 "$REALITY_KEY_FILE"
    fi
    REALITY_PRIV=$(awk -F': ' '/PrivateKey/{print $2}' "$REALITY_KEY_FILE" | tr -d '[:space:]')
    REALITY_PUB=$(awk  -F': ' '/PublicKey/{print $2}'  "$REALITY_KEY_FILE" | tr -d '[:space:]')
    [[ -z "$REALITY_PRIV" || -z "$REALITY_PUB" ]] && die "Corrupt keypair at $REALITY_KEY_FILE"
}

load_secret() {
    local kind="$1" port="$2"
    local f="$STATE_DIR/${kind}-${port}.secret"
    [[ -s "$f" ]] && cat "$f" && return
    local v
    case "$kind" in
        uuid)        v=$(gen_uuid) ;;
        password)    v=$(gen_password) ;;
        ss2022-key)  v=$(gen_ss2022_key) ;;
        *) die "unknown secret kind: $kind" ;;
    esac
    echo -n "$v" > "$f"; chmod 600 "$f"
    echo -n "$v"
}

regen_secret() {
    local kind="$1" port="$2"
    rm -f "$STATE_DIR/${kind}-${port}.secret"
    load_secret "$kind" "$port"
}

protocol_transport() {
    case "$1" in
        vless-reality|vmess-ws|trojan-ws|shadowsocks) echo "tcp" ;;
        hysteria|hysteria2|tuic)                      echo "udp" ;;
        *) die "Unknown protocol: $1" ;;
    esac
}

inbound_type_to_protocol() {
    case "$1" in
        vless)        echo "vless-reality" ;;
        vmess)        echo "vmess-ws" ;;
        trojan)       echo "trojan-ws" ;;
        hysteria)     echo "hysteria" ;;
        hysteria2)    echo "hysteria2" ;;
        shadowsocks)  echo "shadowsocks" ;;
        *) echo "$1" ;;
    esac
}

check_port_free() {
    local port="$1" transport="$2" our_tag="$3"
    IDEMPOTENT_RETRY=0
    local conflicts=()

    if [[ -f "$SINGBOX_CONF" ]]; then
        while IFS='|' read -r ex_type ex_tag; do
            [[ -z "$ex_type" ]] && continue
            local ex_t
            case "$ex_type" in hysteria|hysteria2|tuic) ex_t="udp" ;; *) ex_t="tcp" ;; esac
            if [[ "$ex_t" == "$transport" ]]; then
                if [[ "$ex_tag" == "$our_tag" ]]; then
                    IDEMPOTENT_RETRY=1
                    info "Existing inbound '$ex_tag' matches — idempotent retry."
                else
                    conflicts+=("server inbound '$ex_tag' (type=$ex_type, $ex_t)")
                fi
            fi
        done < <(jq -r --argjson p "$port" '
            .inbounds[]? | select(.listen_port == $p) | "\(.type)|\(.tag)"
        ' "$SINGBOX_CONF" 2>/dev/null)
    fi

    local ss_flag
    [[ "$transport" == "tcp" ]] && ss_flag="-tlnp" || ss_flag="-ulnp"
    if command -v ss >/dev/null; then
        local who; who=$(ss -H $ss_flag "sport = :${port}" 2>/dev/null | awk '{print $NF}' | head -1)
        if [[ -n "$who" ]]; then
            if (( IDEMPOTENT_RETRY == 1 )) && echo "$who" | grep -q "sing-box"; then
                : # our own
            else
                conflicts+=("kernel listener on $port/$transport: $who")
            fi
        fi
    fi

    if (( ${#conflicts[@]} > 0 )); then
        err "Port ${port}/${transport} is already in use:"
        for c in "${conflicts[@]}"; do echo "        - $c"; done
        echo
        echo "    Note: TCP and UDP on the same port are independent."
        echo "    e.g. vless-reality on TCP/443 + hysteria2 on UDP/443 is fine."
        die "Choose a different port and re-run."
    fi
    if (( IDEMPOTENT_RETRY == 1 )); then
        ok "Port $port/$transport held by '$our_tag' — proceeding as upsert."
    else
        ok "Port $port/$transport is free."
    fi
}

build_vless_reality() {
    local port="$1" tag="$2" sni_override="${3:-}"
    ensure_reality_keypair

    local sni saved
    if [[ -n "$sni_override" ]]; then
        sni="$sni_override"; save_port_sni "$port" "$sni"
    else
        saved=$(get_port_sni "$port")
        if [[ -n "$saved" ]]; then sni="$saved"
        else
            sni=$(pick_sni_for_port "$port"); save_port_sni "$port" "$sni"
        fi
    fi
    UUID=$(load_secret uuid "$port")

    INBOUND_JSON=$(jq -n \
        --arg tag "$tag" --argjson port "$port" \
        --arg uuid "$UUID" --arg sni "$sni" \
        --arg priv "$REALITY_PRIV" --arg sid "$SHORT_ID" '
        { type: "vless", tag: $tag, listen: "::", listen_port: $port,
          users: [{ uuid: $uuid, flow: "xtls-rprx-vision" }],
          tls: { enabled: true, server_name: $sni,
                 reality: { enabled: true,
                            handshake: { server: $sni, server_port: 443 },
                            private_key: $priv, short_id: [ $sid ] } },
          multiplex: { enabled: true, padding: false } }')

    OUTBOUND_JSON=$(jq -n \
        --arg tag "$tag" --arg server "$PUBLIC_IP" --argjson port "$port" \
        --arg uuid "$UUID" --arg sni "$sni" \
        --arg pub "$REALITY_PUB" --arg sid "$SHORT_ID" '
        { type: "vless", tag: $tag, server: $server, server_port: $port,
          uuid: $uuid, packet_encoding: "xudp", flow: "xtls-rprx-vision",
          multiplex: { enabled: false },
          tls: { enabled: true, server_name: $sni, insecure: false,
                 utls: { enabled: true, fingerprint: "chrome" },
                 reality: { enabled: true, public_key: $pub, short_id: $sid } },
          tcp_fast_open: true, tcp_multi_path: false }')

    SUMMARY_LINES=("UUID: $UUID" "SNI: $sni" "Public Key: $REALITY_PUB" "Short ID: $SHORT_ID")
    LAST_SNI="$sni"
}

build_vmess_ws() {
    local port="$1" tag="$2"
    ensure_self_signed_cert
    UUID=$(load_secret uuid "$port")
    local pf="$STATE_DIR/vmess-${port}.path"
    [[ ! -s "$pf" ]] && head -c 6 /dev/urandom | xxd -p > "$pf"
    WSPATH="/$(cat "$pf")"

    INBOUND_JSON=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg uuid "$UUID" \
        --arg crt "$SS_CRT" --arg key "$SS_KEY" --arg path "$WSPATH" '
        { type: "vmess", tag: $tag, listen: "::", listen_port: $port,
          users: [{ uuid: $uuid, alterId: 0 }],
          tls: { enabled: true, certificate_path: $crt, key_path: $key },
          transport: { type: "ws", path: $path } }')

    OUTBOUND_JSON=$(jq -n \
        --arg tag "$tag" --arg server "$PUBLIC_IP" --argjson port "$port" \
        --arg uuid "$UUID" --arg path "$WSPATH" '
        { type: "vmess", tag: $tag, server: $server, server_port: $port,
          uuid: $uuid, security: "auto", alter_id: 0,
          tls: { enabled: true, insecure: true, server_name: "bing.com" },
          transport: { type: "ws", path: $path } }')

    SUMMARY_LINES=("UUID: $UUID" "WS Path: $WSPATH" "TLS: self-signed")
}

build_trojan_ws() {
    local port="$1" tag="$2"
    ensure_self_signed_cert
    PASSWORD=$(load_secret password "$port")
    local pf="$STATE_DIR/trojan-${port}.path"
    [[ ! -s "$pf" ]] && head -c 6 /dev/urandom | xxd -p > "$pf"
    WSPATH="/$(cat "$pf")"

    INBOUND_JSON=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg pw "$PASSWORD" \
        --arg crt "$SS_CRT" --arg key "$SS_KEY" --arg path "$WSPATH" '
        { type: "trojan", tag: $tag, listen: "::", listen_port: $port,
          users: [{ password: $pw }],
          tls: { enabled: true, certificate_path: $crt, key_path: $key },
          transport: { type: "ws", path: $path } }')

    OUTBOUND_JSON=$(jq -n \
        --arg tag "$tag" --arg server "$PUBLIC_IP" --argjson port "$port" \
        --arg pw "$PASSWORD" --arg path "$WSPATH" '
        { type: "trojan", tag: $tag, server: $server, server_port: $port,
          password: $pw,
          tls: { enabled: true, insecure: true, server_name: "bing.com" },
          transport: { type: "ws", path: $path } }')

    SUMMARY_LINES=("Password: $PASSWORD" "WS Path: $WSPATH" "TLS: self-signed")
}

build_hysteria() {
    local port="$1" tag="$2"
    ensure_self_signed_cert
    PASSWORD=$(load_secret password "$port")

    warn "hysteria v1 is legacy — prefer hysteria2 unless you specifically need it"

    INBOUND_JSON=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg pw "$PASSWORD" \
        --arg crt "$SS_CRT" --arg key "$SS_KEY" '
        { type: "hysteria", tag: $tag, listen: "::", listen_port: $port,
          users: [{ auth_str: $pw }],
          up_mbps: 100, down_mbps: 100,
          tls: { enabled: true, alpn: ["h3"],
                 certificate_path: $crt, key_path: $key } }')

    OUTBOUND_JSON=$(jq -n \
        --arg tag "$tag" --arg server "$PUBLIC_IP" --argjson port "$port" \
        --arg pw "$PASSWORD" '
        { type: "hysteria", tag: $tag, server: $server, server_port: $port,
          auth_str: $pw, up_mbps: 50, down_mbps: 100,
          disable_mtu_discovery: false,
          tls: { enabled: true, alpn: ["h3"], insecure: true, server_name: "bing.com" } }')

    SUMMARY_LINES=("Auth: $PASSWORD" "Up/Down: 50/100 mbps" "TLS: self-signed")
}

build_hysteria2() {
    local port="$1" tag="$2"
    ensure_self_signed_cert
    PASSWORD=$(load_secret password "$port")

    INBOUND_JSON=$(jq -n \
        --arg tag "$tag" --argjson port "$port" --arg pw "$PASSWORD" \
        --arg crt "$SS_CRT" --arg key "$SS_KEY" '
        { type: "hysteria2", tag: $tag, listen: "::", listen_port: $port,
          users: [{ password: $pw }], ignore_client_bandwidth: false,
          tls: { enabled: true, alpn: ["h3"],
                 certificate_path: $crt, key_path: $key } }')

    OUTBOUND_JSON=$(jq -n \
        --arg tag "$tag" --arg server "$PUBLIC_IP" --argjson port "$port" \
        --arg pw "$PASSWORD" '
        { type: "hysteria2", tag: $tag, server: $server, server_port: $port,
          password: $pw,
          tls: { enabled: true, alpn: ["h3"], insecure: true, server_name: "bing.com" } }')

    SUMMARY_LINES=("Password: $PASSWORD" "TLS: self-signed")
}

build_shadowsocks() {
    local port="$1" tag="$2"
    local key; key=$(load_secret ss2022-key "$port")
    local method="2022-blake3-aes-256-gcm"

    INBOUND_JSON=$(jq -n \
        --arg tag "$tag" --argjson port "$port" \
        --arg method "$method" --arg pw "$key" '
        { type: "shadowsocks", tag: $tag, listen: "::", listen_port: $port,
          method: $method, password: $pw }')

    OUTBOUND_JSON=$(jq -n \
        --arg tag "$tag" --arg server "$PUBLIC_IP" --argjson port "$port" \
        --arg method "$method" --arg pw "$key" '
        { type: "shadowsocks", tag: $tag, server: $server, server_port: $port,
          method: $method, password: $pw }')

    SUMMARY_LINES=("Method: $method" "Key: $key")
}

dispatch_build() {
    local protocol="$1" port="$2" tag="$3" sni_override="${4:-}"
    case "$protocol" in
        vless-reality) build_vless_reality "$port" "$tag" "$sni_override" ;;
        vmess-ws)
            [[ -n "$sni_override" ]] && warn "--sni ignored for vmess-ws"
            build_vmess_ws "$port" "$tag" ;;
        trojan-ws)
            [[ -n "$sni_override" ]] && warn "--sni ignored for trojan-ws"
            build_trojan_ws "$port" "$tag" ;;
        hysteria)
            [[ -n "$sni_override" ]] && warn "--sni ignored for hysteria"
            build_hysteria "$port" "$tag" ;;
        hysteria2)
            [[ -n "$sni_override" ]] && warn "--sni ignored for hysteria2"
            build_hysteria2 "$port" "$tag" ;;
        shadowsocks)
            [[ -n "$sni_override" ]] && warn "--sni ignored for shadowsocks"
            build_shadowsocks "$port" "$tag" ;;
        *) die "Unknown protocol: $protocol" ;;
    esac
}

bootstrap_server_config() {
    [[ -f "$SINGBOX_CONF" ]] && jq -e '.inbounds' "$SINGBOX_CONF" >/dev/null 2>&1 && return
    info "Bootstrapping fresh server config..."
    mkdir -p "$SINGBOX_CONF_DIR"
    cat > "$SINGBOX_CONF" <<'EOF'
{
  "log": { "level": "info", "timestamp": true, "output": "/tmp/singbox.log" },
  "inbounds": [],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "rules": [], "final": "direct" }
}
EOF
}

upsert_server_inbound() {
    local tag="$1" inbound_json="$2"
    local backup="$SINGBOX_CONF.bak-$(date +%s)"
    cp "$SINGBOX_CONF" "$backup"
    local TMP; TMP=$(mktemp)
    if ! jq --argjson nb "$inbound_json" --arg t "$tag" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $t)) + [$nb])
    ' "$SINGBOX_CONF" > "$TMP" 2>>"$LOG_FILE"; then
        rm -f "$TMP"; die "jq upsert failed (server config)"
    fi
    mv "$TMP" "$SINGBOX_CONF"
    if ! singbox_check_loud "$SINGBOX_CONF" "server config"; then
        warn "Rolling back to $backup"
        mv "$backup" "$SINGBOX_CONF"; die "Validation failed"
    fi
    rm -f "$backup"
}

bootstrap_master_client() {
    [[ -f "$CLIENT_MASTER" ]] && return
    info "Bootstrapping master client config: $CLIENT_MASTER"
    mkdir -p "$CLIENT_DIR"
    cat > "$CLIENT_MASTER" <<'CLIENTEOF'
{
  "log": { "disabled": false, "level": "warn", "timestamp": false },
  "dns": {
    "servers": [
      { "tag": "local-dns",   "address": "223.5.5.5", "strategy": "ipv4_only", "detour": "direct" },
      { "tag": "remote-dns",  "address": "8.8.8.8",   "strategy": "ipv4_only", "detour": "proxy"  },
      { "tag": "facebook-dns","address": "https://8.8.8.8/dns-query",
        "address_resolver": "remote-dns", "strategy": "ipv4_only", "detour": "proxy" },
      { "tag": "fakeip",      "address": "fakeip" },
      { "tag": "block",       "address": "rcode://success" }
    ],
    "rules": [
      { "rule_set": "geosite-ads", "server": "block", "disable_cache": true },
      { "clash_mode": "Direct Mode", "server": "local-dns" },
      { "clash_mode": "Global Mode", "server": "remote-dns" },
      { "domain_suffix": [
          "facebook.com","fb.com","fbcdn.net","facebook.net","fbsbx.com",
          "messenger.com","m.me","instagram.com","cdninstagram.com",
          "whatsapp.com","whatsapp.net","wa.me"
        ], "server": "facebook-dns" },
      { "rule_set": "geosite-cn", "server": "local-dns" },
      { "rule_set": "geoip-cn",   "server": "local-dns" }
    ],
    "fakeip": { "enabled": true, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18" },
    "strategy": "prefer_ipv4",
    "independent_cache": true,
    "final": "remote-dns"
  },
  "inbounds": [
    {
      "type": "tun", "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "mtu": 9000, "auto_route": true, "strict_route": true,
      "stack": "system", "sniff": true, "sniff_override_destination": false
    }
  ],
  "outbounds": [
    { "type": "selector", "tag": "proxy",
      "outbounds": ["auto", "__PLACEHOLDER__"], "default": "auto" },
    { "type": "urltest", "tag": "auto",
      "url": "http://www.gstatic.com/generate_204",
      "interval": "3m", "tolerance": 50,
      "outbounds": ["__PLACEHOLDER__"] },
    { "type": "selector", "tag": "facebook-proxy",
      "outbounds": ["proxy", "__PLACEHOLDER__"], "default": "proxy" },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "clash_mode": "Direct Mode", "outbound": "direct" },
      { "clash_mode": "Global Mode", "outbound": "proxy"  },
      { "protocol": "stun", "outbound": "facebook-proxy" },
      { "domain_suffix": [
          "facebook.com","fb.com","fbcdn.net","facebook.net","fbsbx.com",
          "messenger.com","m.me","instagram.com","cdninstagram.com",
          "whatsapp.com","whatsapp.net","wa.me"
        ], "outbound": "facebook-proxy" },
      { "domain_keyword": ["facebook","fbcdn","messenger","whatsapp"],
        "outbound": "facebook-proxy" },
      { "ip_cidr": [
          "31.13.24.0/21","31.13.64.0/18","45.64.40.0/22","66.220.144.0/20",
          "69.63.176.0/20","69.171.224.0/19","74.119.76.0/22","103.4.96.0/22",
          "129.134.0.0/16","157.240.0.0/17","173.252.64.0/18","179.60.192.0/22",
          "185.60.216.0/22","204.15.20.0/22"
        ], "outbound": "facebook-proxy" },
      { "network": "udp", "port": [53, 443, 3478, 5349],
        "outbound": "facebook-proxy" },
      { "network": "udp", "port_range": ["50000:65535"],
        "outbound": "facebook-proxy" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": "geoip-cn",   "outbound": "direct" },
      { "rule_set": "geosite-cn", "outbound": "direct" }
    ],
    "rule_set": [
      { "tag": "geoip-cn", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "direct", "update_interval": "7d" },
      { "tag": "geosite-cn", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "direct", "update_interval": "7d" },
      { "tag": "geosite-ads", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs",
        "download_detour": "direct", "update_interval": "7d" }
    ],
    "final": "proxy",
    "auto_detect_interface": true
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "cache.db", "cache_id": "mycache", "store_fakeip": true },
    "clash_api":  { "external_controller": "127.0.0.1:9090", "external_ui": "", "secret": "",
                    "default_mode": "Smart Mode" }
  }
}
CLIENTEOF
}

migrate_legacy_master() {
    [[ ! -f "$CLIENT_MASTER" ]] && return
    local has_legacy
    has_legacy=$(jq 'any(.inbounds[]?; has("inet4_address") or has("inet6_address"))' "$CLIENT_MASTER" 2>/dev/null)
    [[ "$has_legacy" != "true" ]] && return
    warn "Master client uses legacy TUN fields — migrating to 1.11 schema"
    local backup="$CLIENT_MASTER.legacy-$(date +%s)"; cp "$CLIENT_MASTER" "$backup"
    local TMP; TMP=$(mktemp)
    jq '
        .inbounds = (.inbounds // [] | map(
            if .type == "tun" then
                .address = (
                    ((.inet4_address // []) | (if type=="string" then [.] else . end))
                    + ((.inet6_address // []) | (if type=="string" then [.] else . end))
                ) | del(.inet4_address) | del(.inet6_address)
            else . end
        ))
    ' "$CLIENT_MASTER" > "$TMP" || { rm -f "$TMP"; die "migration jq failed"; }
    mv "$TMP" "$CLIENT_MASTER"
    ok "Migrated. Backup: $backup"
}

upsert_master_outbound() {
    local outbound_json="$1" tag="$2"
    bootstrap_master_client
    migrate_legacy_master

    info "Upserting '$tag' in master client config..."
    local backup="$CLIENT_MASTER.bak-$(date +%s)"
    cp "$CLIENT_MASTER" "$backup"

    local TMP; TMP=$(mktemp)
    if ! jq --argjson ob "$outbound_json" --arg tag "$tag" '
        .outbounds = ((.outbounds // []) | map(select(.tag != $tag)) + [$ob])
        | .outbounds = (
            .outbounds | map(
                if .tag == "proxy" then
                    .outbounds = (
                        ((.outbounds // []) + [$tag])
                        | map(select(. != "__PLACEHOLDER__")) | unique_by(.)
                        | (if any(.; . == "auto")
                           then ["auto"] + map(select(. != "auto")) else . end)
                    )
                elif .tag == "auto" then
                    .outbounds = (
                        ((.outbounds // []) + [$tag])
                        | map(select(. != "__PLACEHOLDER__")) | unique_by(.)
                    )
                elif .tag == "facebook-proxy" then
                    .outbounds = (
                        ((.outbounds // []) + [$tag])
                        | map(select(. != "__PLACEHOLDER__")) | unique_by(.)
                        | (if any(.; . == "proxy")
                           then ["proxy"] + map(select(. != "proxy")) else . end)
                    )
                else . end
            )
          )
    ' "$CLIENT_MASTER" > "$TMP" 2>>"$LOG_FILE"; then
        rm -f "$TMP"; mv "$backup" "$CLIENT_MASTER"
        die "jq upsert failed (master client)"
    fi
    mv "$TMP" "$CLIENT_MASTER"

    if ! singbox_check_loud "$CLIENT_MASTER" "master client"; then
        warn "Rolling back master client to: $backup"
        mv "$backup" "$CLIENT_MASTER"; die "Master client validation failed"
    fi
    rm -f "$backup"
}

write_per_install_client() {
    local outbound_json="$1" tag="$2"
    local out="$CLIENT_DIR/sing-box-client-${tag}.txt"

    info "Writing per-install client: $out"

    local TMP; TMP=$(mktemp)
    if ! jq --argjson ob "$outbound_json" --arg tag "$tag" '
        .outbounds = [
            { type: "selector", tag: "proxy",
              outbounds: [$tag], default: $tag },
            { type: "urltest", tag: "auto",
              url: "http://www.gstatic.com/generate_204",
              interval: "3m", tolerance: 50,
              outbounds: [$tag] },
            $ob,
            { type: "direct", tag: "direct" }
        ]
        | .route.final = "proxy"
        | .route.rules = (.route.rules // []
            | map(if .outbound == "facebook-proxy" then .outbound = "proxy" else . end)
            | map(select((.outbound // "") != "facebook-proxy")))
    ' "$CLIENT_MASTER" > "$TMP" 2>>"$LOG_FILE"; then
        rm -f "$TMP"; die "jq render failed (per-install client)"
    fi

    if ! "$SINGBOX_BIN" check -c "$TMP" >>"$LOG_FILE" 2>&1; then
        local check_out
        check_out=$("$SINGBOX_BIN" check -c "$TMP" 2>&1)
        rm -f "$TMP"
        err "Per-install client failed validation:"; indent "$check_out"
        die "Aborting per-install client write"
    fi

    mv "$TMP" "$out"
    chmod 600 "$out"
    ok "Per-install client: $out"
}

install_systemd_unit() {
    if [[ -f "$SINGBOX_SERVICE" ]] && \
       grep -q "ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONF" "$SINGBOX_SERVICE"; then
        return
    fi
    info "Installing systemd unit..."
    cat > "$SINGBOX_SERVICE" <<EOF
[Unit]
Description=sing-box (multi-protocol)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=$SINGBOX_CONF_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >>"$LOG_FILE" 2>&1
    ok "systemd unit installed"
}

restart_service() {
    info "Restarting sing-box..."
    systemctl restart sing-box; sleep 2
    if ! systemctl is-active --quiet sing-box; then
        err "sing-box failed to start. Last 30 journal lines:"
        indent "$(journalctl -u sing-box -n 30 --no-pager 2>&1)"
        die "Service not active"
    fi
    ok "sing-box running"
}

open_firewall_port() {
    local p="$1" t="$2"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$p/$t" >>"$LOG_FILE" 2>&1; ok "ufw: $p/$t allowed"
    elif command -v iptables &>/dev/null; then
        iptables  -C INPUT -p "$t" --dport "$p" -j ACCEPT 2>/dev/null \
            || iptables  -A INPUT -p "$t" --dport "$p" -j ACCEPT
        ip6tables -C INPUT -p "$t" --dport "$p" -j ACCEPT 2>/dev/null \
            || ip6tables -A INPUT -p "$t" --dport "$p" -j ACCEPT
        [[ -e /etc/iptables/rules.v4 ]] && iptables-save  > /etc/iptables/rules.v4
        [[ -e /etc/iptables/rules.v6 ]] && ip6tables-save > /etc/iptables/rules.v6
        ok "iptables: $p/$t allowed"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
        firewall-cmd --zone=public --add-port="$p/$t" --permanent >>"$LOG_FILE" 2>&1
        firewall-cmd --reload >>"$LOG_FILE" 2>&1
        ok "firewalld: $p/$t allowed"
    else
        warn "No active firewall — open $p/$t manually if needed."
    fi
}

cmd_install() {
    local protocol="${1:-}" port="${2:-}"
    [[ -z "$protocol" || -z "$port" ]] && { usage; exit 1; }
    shift 2 || true

    local sni_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sni) sni_override="${2:-}"; [[ -z "$sni_override" ]] && die "--sni needs a value"; shift 2 ;;
            *) die "Unknown flag: $1" ;;
        esac
    done

    case "$protocol" in
        vless-reality|vmess-ws|trojan-ws|hysteria|hysteria2|shadowsocks) ;;
        *) die "Unknown protocol: $protocol (run '$0 help' for list)" ;;
    esac
    [[ "$port" =~ ^[0-9]+$ ]] || die "PORT must be numeric: $port"
    (( port >= 1 && port <= 65535 )) || die "PORT out of range: $port"

    local transport tag
    transport=$(protocol_transport "$protocol")
    tag="${protocol}-${port}"

    : > "$LOG_FILE"
    echo
    banner "════════════════════════════════════════════════════════════"
    banner "  install $protocol on $port/$transport"
    [[ -n "$sni_override" ]] && banner "  forced SNI: $sni_override"
    banner "════════════════════════════════════════════════════════════"
    echo

    ensure_hostname_in_hosts
    ensure_deps
    ensure_singbox
    detect_public_ip
    check_port_free "$port" "$transport" "$tag"

    dispatch_build "$protocol" "$port" "$tag" "$sni_override"

    bootstrap_server_config
    upsert_server_inbound "$tag" "$INBOUND_JSON"
    install_systemd_unit
    restart_service
    open_firewall_port "$port" "$transport"

    upsert_master_outbound  "$OUTBOUND_JSON" "$tag"
    write_per_install_client "$OUTBOUND_JSON" "$tag"

    echo
    banner "╔══════════════════════════════════════════════════════════════╗"
    banner "║  '$tag' installed and active                                 "
    banner "╚══════════════════════════════════════════════════════════════╝"
    echo
    echo -e "${BOLD}── Inbound details ──${NC}"
    echo "  Server   : $PUBLIC_IP"
    echo "  Protocol : $protocol"
    echo "  Listen   : $port/$transport"
    for line in "${SUMMARY_LINES[@]}"; do echo "  $line"; done
    echo
    echo -e "${BOLD}── All inbounds on this VPS ──${NC}"
    jq -r '.inbounds[] | "  • \(.tag) — \(.type) on \(.listen_port)"' "$SINGBOX_CONF"
    echo
    echo -e "${BOLD}── Files ──${NC}"
    echo "  Server config       : $SINGBOX_CONF"
    echo "  Master client       : $CLIENT_MASTER"
    echo "  Per-install client  : $CLIENT_DIR/sing-box-client-${tag}.txt"
    echo
    echo -e "${BOLD}── Master client 'proxy' selector now contains ──${NC}"
    jq -r '.outbounds[] | select(.tag=="proxy") | .outbounds[] | "  • \(.)"' "$CLIENT_MASTER"
    echo
}

cmd_remove() {
    local tag="${1:-}"
    [[ -z "$tag" ]] && die "Usage: $0 remove <TAG>"
    [[ ! -f "$SINGBOX_CONF" ]] && die "No server config"

    local n
    n=$(jq --arg t "$tag" '[.inbounds[]? | select(.tag == $t)] | length' "$SINGBOX_CONF")
    [[ "$n" == "0" ]] && warn "Tag '$tag' not in server config (will still clean up client side)"

    if [[ "$n" != "0" ]]; then
        local backup="$SINGBOX_CONF.bak-$(date +%s)"; cp "$SINGBOX_CONF" "$backup"
        local TMP; TMP=$(mktemp)
        jq --arg t "$tag" '.inbounds = (.inbounds // [] | map(select(.tag != $t)))' \
            "$SINGBOX_CONF" > "$TMP"
        mv "$TMP" "$SINGBOX_CONF"
        if ! singbox_check_loud "$SINGBOX_CONF" "server config (post-remove)"; then
            mv "$backup" "$SINGBOX_CONF"; die "Rolled back"
        fi
        rm -f "$backup"
    fi

    if [[ -f "$CLIENT_MASTER" ]]; then
        local cb="$CLIENT_MASTER.bak-$(date +%s)"; cp "$CLIENT_MASTER" "$cb"
        local TMP; TMP=$(mktemp)
        jq --arg t "$tag" '
            .outbounds = (.outbounds // [] | map(select(.tag != $t)))
            | .outbounds = (.outbounds | map(
                if (.type == "selector" or .type == "urltest") then
                    .outbounds = (.outbounds // [] | map(select(. != $t)))
                else . end
            ))
        ' "$CLIENT_MASTER" > "$TMP"
        mv "$TMP" "$CLIENT_MASTER"
        if ! singbox_check_loud "$CLIENT_MASTER" "master client (post-remove)"; then
            mv "$cb" "$CLIENT_MASTER"; die "Rolled back master"
        fi
        rm -f "$cb"
    fi

    rm -f "$CLIENT_DIR/sing-box-client-${tag}.txt"
    local port="${tag##*-}"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        rm -f "$STATE_DIR/uuid-${port}.secret" \
              "$STATE_DIR/password-${port}.secret" \
              "$STATE_DIR/ss2022-key-${port}.secret" \
              "$STATE_DIR/sni-${port}.txt" \
              "$STATE_DIR/trojan-${port}.path" \
              "$STATE_DIR/vmess-${port}.path"
    fi

    systemctl restart sing-box || true
    ok "Removed '$tag' (server + master client + per-install client + secrets)"
}

cmd_list() {
    if [[ -f "$SINGBOX_CONF" ]]; then
        echo -e "${BOLD}── Server inbounds ──${NC}"
        jq -r '.inbounds[]? | "  \(.tag)  type=\(.type)  port=\(.listen_port)"' "$SINGBOX_CONF"
    else
        warn "No server config yet"
    fi
    echo
    if [[ -f "$CLIENT_MASTER" ]]; then
        echo -e "${BOLD}── Master client outbounds (proxy selector) ──${NC}"
        jq -r '.outbounds[] | select(.tag=="proxy") | .outbounds[] | "  • \(.)"' "$CLIENT_MASTER"
    else
        warn "No master client yet"
    fi
    echo
    if ls "$CLIENT_DIR"/sing-box-client-*.txt >/dev/null 2>&1; then
        echo -e "${BOLD}── Per-install client files ──${NC}"
        for f in "$CLIENT_DIR"/sing-box-client-*.txt; do
            [[ "$f" == "$CLIENT_MASTER" ]] && continue
            echo "  $f"
        done
    fi
}

cmd_show() {
    local tag="${1:-}"
    [[ -z "$tag" ]] && die "Usage: $0 show <TAG>"
    local f="$CLIENT_DIR/sing-box-client-${tag}.txt"
    [[ ! -f "$f" ]] && die "No per-install client for '$tag' (file: $f)"
    cat "$f"
}

cmd_show_master() {
    [[ ! -f "$CLIENT_MASTER" ]] && die "No master client yet — install at least one inbound."
    cat "$CLIENT_MASTER"
}

cmd_regen_uuid() {
    local tag="${1:-}"
    [[ -z "$tag" ]] && die "Usage: $0 regen-uuid <TAG>"
    [[ ! -f "$SINGBOX_CONF" ]] && die "No server config"

    local proto port
    proto=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .type'        "$SINGBOX_CONF")
    port=$(jq  -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .listen_port' "$SINGBOX_CONF")
    [[ -z "$proto" ]] && die "Tag '$tag' not found"

    detect_public_ip

    info "Rotating credentials for '$tag' (type=$proto, port=$port)..."
    case "$proto" in
        vless)
            regen_secret uuid "$port" >/dev/null
            build_vless_reality "$port" "$tag" "$(get_port_sni "$port")"
            ;;
        vmess)
            regen_secret uuid "$port" >/dev/null
            build_vmess_ws "$port" "$tag"
            ;;
        trojan)
            regen_secret password "$port" >/dev/null
            build_trojan_ws "$port" "$tag"
            ;;
        hysteria)
            regen_secret password "$port" >/dev/null
            build_hysteria "$port" "$tag"
            ;;
        hysteria2)
            regen_secret password "$port" >/dev/null
            build_hysteria2 "$port" "$tag"
            ;;
        shadowsocks)
            regen_secret ss2022-key "$port" >/dev/null
            build_shadowsocks "$port" "$tag"
            ;;
        *) die "regen-uuid: unsupported type=$proto" ;;
    esac

    upsert_server_inbound "$tag" "$INBOUND_JSON"
    upsert_master_outbound  "$OUTBOUND_JSON" "$tag"
    write_per_install_client "$OUTBOUND_JSON" "$tag"
    restart_service

    echo
    ok "Credentials rotated for $tag"
    for line in "${SUMMARY_LINES[@]}"; do echo "  $line"; done
    warn "Update any clients using these credentials. Per-install file rewritten:"
    echo "  $CLIENT_DIR/sing-box-client-${tag}.txt"
}

cmd_regen_sni() {
    local tag="${1:-}"
    [[ -z "$tag" ]] && die "Usage: $0 regen-sni <TAG> [--sni DOMAIN]"
    shift || true
    local sni_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sni) sni_override="${2:-}"; shift 2 ;;
            *) die "Unknown flag: $1" ;;
        esac
    done

    local proto port
    proto=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .type'        "$SINGBOX_CONF")
    port=$(jq  -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .listen_port' "$SINGBOX_CONF")
    [[ -z "$proto" ]] && die "Tag '$tag' not found"
    [[ "$proto" != "vless" ]] && die "regen-sni only applies to vless-reality (got type=$proto)"

    if [[ -z "$sni_override" ]]; then
        rm -f "$STATE_DIR/sni-${port}.txt"
        sni_override=$(pick_sni_for_port "$port")
    fi

    detect_public_ip
    info "Reassigning SNI for $tag (port $port) → $sni_override"

    save_port_sni "$port" "$sni_override"
    build_vless_reality "$port" "$tag" "$sni_override"
    upsert_server_inbound "$tag" "$INBOUND_JSON"
    upsert_master_outbound  "$OUTBOUND_JSON" "$tag"
    write_per_install_client "$OUTBOUND_JSON" "$tag"
    restart_service

    ok "SNI reassigned: $LAST_SNI"
    for line in "${SUMMARY_LINES[@]}"; do echo "  $line"; done
    warn "Update any clients using this node. Per-install file rewritten:"
    echo "  $CLIENT_DIR/sing-box-client-${tag}.txt"
}

cmd_set_sni_pool() {
    local csv="${1:-}"
    [[ -z "$csv" ]] && die "Usage: $0 set-sni-pool d1,d2,d3,..."
    : > "$SNI_POOL_FILE"
    IFS=',' read -ra entries <<< "$csv"
    for d in "${entries[@]}"; do
        d=$(echo "$d" | tr -d '[:space:]')
        [[ -n "$d" ]] && echo "$d" >> "$SNI_POOL_FILE"
    done
    chmod 600 "$SNI_POOL_FILE"
    ok "SNI pool saved → $SNI_POOL_FILE"
    indent "$(cat "$SNI_POOL_FILE")"
}

cmd_show_sni_pool() {
    if [[ -s "$SNI_POOL_FILE" ]]; then
        echo -e "${BOLD}── SNI pool (custom) ──${NC}"
        cat "$SNI_POOL_FILE"
    else
        echo -e "${BOLD}── SNI pool (built-in default) ──${NC}"
        printf '  %s\n' "${DEFAULT_SNI_POOL[@]}"
    fi
}

cmd_doctor() {
    : > "$LOG_FILE"
    echo -e "${BOLD}── Binary ──${NC}"
    [[ -f "$SINGBOX_BIN" ]] \
        && ok "$SINGBOX_BIN ($("$SINGBOX_BIN" version 2>/dev/null | head -1))" \
        || err "missing"

    echo
    echo -e "${BOLD}── Config paths ──${NC}"
    [[ -f "$SINGBOX_CONF"  ]] && ok "server : $SINGBOX_CONF"   || warn "no server config"
    [[ -f "$CLIENT_MASTER" ]] && ok "master : $CLIENT_MASTER"  || warn "no master client"
    [[ -f /etc/sing-box/config.json ]] && warn "foreign config also present at /etc/sing-box/config.json"

    echo
    echo -e "${BOLD}── systemd unit ──${NC}"
    if [[ -f "$SINGBOX_SERVICE" ]]; then
        local exec_line; exec_line=$(grep ^ExecStart= "$SINGBOX_SERVICE")
        echo "  $exec_line"
        echo "$exec_line" | grep -q "$SINGBOX_CONF" \
            && ok "unit points at managed config" \
            || err "unit does NOT point at $SINGBOX_CONF"
    else
        warn "no unit file"
    fi

    echo
    echo -e "${BOLD}── Service ──${NC}"
    systemctl is-active --quiet sing-box && ok "active" || warn "inactive"

    echo
    echo -e "${BOLD}── Listeners ──${NC}"
    if command -v ss >/dev/null; then
        ss -H -tlnp 2>/dev/null | awk '/sing-box/ {print "  TCP " $4}'
        ss -H -ulnp 2>/dev/null | awk '/sing-box/ {print "  UDP " $4}'
    fi

    echo
    [[ -f "$SINGBOX_CONF"  ]] && singbox_check_loud "$SINGBOX_CONF"  "server config"
    [[ -f "$CLIENT_MASTER" ]] && singbox_check_loud "$CLIENT_MASTER" "master client"

    echo
    cmd_show_sni_pool
}

cmd_service() {
    local action="${1:-status}"
    case "$action" in
        start|stop|restart) systemctl "$action" sing-box ;;
        status)             systemctl status sing-box --no-pager -l | head -20 ;;
        logs)               journalctl -u sing-box -f ;;
        *) die "Unknown action: $action (use: start|stop|restart|status|logs)" ;;
    esac
}

require_root
mkdir -p "$STATE_DIR" "$CLIENT_DIR"
touch "$LOG_FILE"

if [[ $# -ge 2 ]] && [[ "${1:-}" =~ ^(vless-reality|vmess-ws|trojan-ws|hysteria|hysteria2|shadowsocks)$ ]]; then
    set -- install "$@"
fi

case "${1:-help}" in
    install)        shift; cmd_install "$@" ;;
    remove)         shift; cmd_remove "$@" ;;
    list)           cmd_list ;;
    show)           shift; cmd_show "$@" ;;
    show-master)    cmd_show_master ;;
    regen-uuid)     shift; cmd_regen_uuid "$@" ;;
    regen-sni)      shift; cmd_regen_sni "$@" ;;
    set-sni-pool)   shift; cmd_set_sni_pool "$@" ;;
    show-sni-pool)  cmd_show_sni_pool ;;
    doctor)         cmd_doctor ;;
    service)        shift; cmd_service "$@" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
