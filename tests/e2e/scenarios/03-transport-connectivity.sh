#!/usr/bin/env bash
# Scenario 3: REAL client-to-upstream connectivity for every transport this
# repo configures. Required follow-up from NEXT_SESSION.md -- the previous
# scenarios only proved API payloads, generated config, listeners, and TLS
# handshakes; none of that proves an actual client can push a byte through
# the tunnel and get a real response back. This scenario starts a REAL
# client for each transport (the same xray-core binary 3x-ui installs, the
# real `hysteria` client, the real `mieru` client, and plain curl for
# NaiveProxy's HTTPS forward proxy) and asserts on the REAL response from a
# real public target (https://example.com) fetched *through* the tunnel --
# not a stub, not a listener check, not just a handshake.
#
# Covers:
#   - VLESS WebSocket   through Nginx (CDN loopback + stream SNI Guard)
#   - VLESS gRPC        through Nginx
#   - VLESS XHTTP       through Nginx
#   - VLESS TCP+Reality direct (no Nginx in the data path)
#   - Hysteria2 direct, including Salamander/finalmask obfuscation
#   - NaiveProxy direct HTTPS forward proxy
#   - mieru direct, username/password, one of its fixed "boring" ports
#
# Why https://example.com and not a local target: install_3xui_and_inbounds
# also runs configure_xray_config, which adds a `geoip:private -> blocked`
# routing rule -- a local loopback/private target would be silently
# blackholed by that real rule, defeating the point of this tier. Fetching a
# real public page through each tunnel is also a strictly stronger proof of
# "this transport actually reaches the internet."
#
# Run inside the e2e container (see run.sh). Exits non-zero with a specific
# message on the first failed assertion.
set -euo pipefail

REPO="/opt/repo"
FAIL=0
MARKER="Example Domain"
TARGET_URL="https://example.com"
CLEANUP_PIDS=()

fail() { echo "FAIL: $*" >&2; FAIL=1; }
ok() { echo "  ok: $*" >&2; }

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$desc"
  else
    fail "${desc}: expected to contain '${needle}', got: ${haystack:0:200}"
  fi
}

cleanup() {
  local pid
  for pid in "${CLEANUP_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

wait_for_local_port() {
  # $1 port, $2 proto (tcp|udp), $3 tries (default 20, 0.5s apart)
  local port="$1" proto="${2:-tcp}" tries="${3:-20}"
  while ((tries-- > 0)); do
    if [[ "$proto" == "udp" ]]; then
      ss -H -lun "sport = :${port}" 2>/dev/null | grep -q . && return 0
    else
      ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
    fi
    sleep 0.5
  done
  return 1
}

cd "$REPO"
chmod +x setup.sh
export VPS_COUNTRY_CODE="EE"
export FALLBACK_HTML_PATH=""
# This E2E tier always runs the container under linux/amd64 (run.sh forces
# it, since NaiveProxy's real binary is amd64-only), which on an arm64 dev
# host (e.g. Apple Silicon) means every Go binary here (xray-core, mita,
# mieru, hysteria) runs under QEMU user-mode emulation. Go's asynchronous
# goroutine preemption is a known crash source under that specific
# emulation (SIGSEGV inside runtime.asyncPreempt), unrelated to any bug in
# the tools themselves -- disabling it is the standard workaround. Native
# amd64 CI runners are unaffected either way.
export GODEBUG="asyncpreemptoff=1"

# shellcheck disable=SC1091
source ./setup.sh

# --- Full variable environment, deliberately combining CDN + direct
# inbounds in one process (something the real interactive flow never
# allows, per validate_inputs's mutual exclusivity) purely so this one
# scenario can exercise every transport against a single running stack.
BASE_DOMAIN="e2e.test"
PANEL_SUBDOMAIN="admin"
VLESS_SUBDOMAIN="lab"
EMAIL="test@e2e.test"
PANEL_PATH="/panel$(openssl rand -hex 4)"
PANEL_PORT=23456
SUB_PORT=23460; WS_PORT=23457; GRPC_PORT=23458; XHTTP_PORT=23459
WS_PATH="/ws1"; GRPC_SERVICE="grpc1"; XHTTP_PATH="/xhttp1"; SUB_PATH="/sub1"
CLIENT_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
CLIENT_SUB_ID="$(openssl rand -hex 8)"

# NOTE: REALITY_SUBDOMAIN/HYSTERIA_SUBDOMAIN are deliberately NOT set yet.
# install_3xui_and_inbounds's own post-call validation checks "is
# REALITY_SUBDOMAIN set" unconditionally (matching real usage, where
# CDN_MODE=true/false is mutually exclusive and REALITY_SUBDOMAIN would
# never be set going into a cdn-mode call) -- it does not know this
# scenario calls the cdn branch first and the no-cdn branch second in the
# same process. Setting them only after the cdn call avoids tripping that
# check on an unrelated call.
REALITY_DEST="github.com"; REALITY_PORT=23461
REALITY_SHORT_ID="deadbeef"

HYSTERIA_PORT=23462
HYSTERIA_AUTH="e2e-hysteria-auth"
HYSTERIA_OBFS_PASSWORD="e2e-salamander-password"

NAIVE_SUBDOMAIN="naive"; NAIVE_PORT=23465
NAIVE_USERNAME="e2euser"; NAIVE_PASSWORD="e2epass$(openssl rand -hex 4)"

MIERU_SUBDOMAIN="mieru"
MIERU_PORTS="53:UDP,853:TCP,993:TCP,8443:TCP"
MIERU_USERNAME="mieru_e2e_user"
MIERU_PASSWORD="mieru_e2e_pass_$(openssl rand -hex 4)"

NGINX_CDN_PORT=23463; NGINX_DECOY_PORT=23464

CERT_DIR="/etc/e2e-selfsigned"
mkdir -p "$CERT_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${CERT_DIR}/privkey.pem" -out "${CERT_DIR}/fullchain.pem" \
  -subj "/CN=${BASE_DOMAIN}" \
  -addext "subjectAltName=DNS:${BASE_DOMAIN},DNS:*.${BASE_DOMAIN}" \
  2>/dev/null

echo "--- Installing real packages (nginx.org repo, certbot, etc.) ---" >&2
install_packages

echo "--- Installing real 3x-ui + CDN inbounds (WS/gRPC/XHTTP + VLESS Encryption) ---" >&2
INSTALL_MODE="cdn"
install_3xui_and_inbounds

echo "--- Adding real Hysteria2 + Reality inbounds via the no-cdn branch ---" >&2
REALITY_SUBDOMAIN="reality"
HYSTERIA_SUBDOMAIN="hy2"
INSTALL_MODE="no-cdn"
run_xui_install_and_inbounds

echo "--- Installing real NaiveProxy (Caddy/forwardproxy) ---" >&2
install_naiveproxy
write_caddyfile
write_naive_systemd_unit

echo "--- Installing real mieru (mita server) ---" >&2
install_mieru
write_mieru_config

echo "--- Writing Nginx config (CDN inbounds behind the stream SNI Guard, alongside Reality/Naive) ---" >&2
INSTALL_MODE="cdn"
write_nginx_config
systemctl restart nginx
[[ "$(systemctl is-active nginx)" == "active" ]] || fail "nginx failed to start"

wait_for_local_port 443 tcp || fail "nginx stream SNI Guard is not listening on :443"

echo "--- Downloading real xray-core client binary (reusing 3x-ui's own build) ---" >&2
XRAY_BIN="$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray-linux-*' | head -1)"
[[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]] || { fail "could not find 3x-ui's xray-linux-* binary"; exit 1; }

run_xray_client() {
  # $1 config file, $2 socks port
  "$XRAY_BIN" run -config "$1" >/tmp/xray-client-"$2".log 2>&1 &
  CLEANUP_PIDS+=("$!")
  wait_for_local_port "$2" tcp || {
    fail "xray client socks inbound never came up on :$2 (log: $(tail -20 /tmp/xray-client-"$2".log))"
    return 1
  }
}

fetch_via_socks() {
  curl -sS --max-time 10 -x "socks5h://127.0.0.1:$1" "$TARGET_URL" 2>"/tmp/curl-$1.err" || true
}

vless_domain="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"

echo "--- VLESS WebSocket through Nginx ---" >&2
cat > /tmp/xray-ws-client.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "port": 11080, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": true } }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{ "address": "127.0.0.1", "port": 443, "users": [{ "id": "${CLIENT_UUID}", "encryption": "${VLESS_ENCRYPTION_CLIENT_KEY}" }] }] },
    "streamSettings": {
      "network": "ws", "security": "tls",
      "tlsSettings": { "serverName": "${vless_domain}", "allowInsecure": true },
      "wsSettings": { "path": "${WS_PATH}", "host": "${vless_domain}" }
    }
  }]
}
EOF
if run_xray_client /tmp/xray-ws-client.json 11080; then
  assert_contains "VLESS WebSocket reaches ${TARGET_URL} through Nginx" "$(fetch_via_socks 11080)" "$MARKER"
fi

echo "--- VLESS gRPC through Nginx ---" >&2
cat > /tmp/xray-grpc-client.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "port": 11081, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": true } }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{ "address": "127.0.0.1", "port": 443, "users": [{ "id": "${CLIENT_UUID}", "encryption": "${VLESS_ENCRYPTION_CLIENT_KEY}" }] }] },
    "streamSettings": {
      "network": "grpc", "security": "tls",
      "tlsSettings": { "serverName": "${vless_domain}", "allowInsecure": true },
      "grpcSettings": { "serviceName": "${GRPC_SERVICE}", "multiMode": false }
    }
  }]
}
EOF
if run_xray_client /tmp/xray-grpc-client.json 11081; then
  assert_contains "VLESS gRPC reaches ${TARGET_URL} through Nginx" "$(fetch_via_socks 11081)" "$MARKER"
fi

echo "--- VLESS XHTTP through Nginx ---" >&2
cat > /tmp/xray-xhttp-client.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "port": 11082, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": true } }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{ "address": "127.0.0.1", "port": 443, "users": [{ "id": "${CLIENT_UUID}", "encryption": "${VLESS_ENCRYPTION_CLIENT_KEY}", "flow": "xtls-rprx-vision" }] }] },
    "streamSettings": {
      "network": "xhttp", "security": "tls",
      "tlsSettings": { "serverName": "${vless_domain}", "allowInsecure": true },
      "xhttpSettings": { "path": "${XHTTP_PATH}", "mode": "packet-up" }
    }
  }]
}
EOF
if run_xray_client /tmp/xray-xhttp-client.json 11082; then
  assert_contains "VLESS XHTTP reaches ${TARGET_URL} through Nginx" "$(fetch_via_socks 11082)" "$MARKER"
fi

echo "--- VLESS TCP+Reality direct (no Nginx in the data path) ---" >&2
cat > /tmp/xray-reality-client.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "port": 11083, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": true } }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{ "address": "127.0.0.1", "port": ${REALITY_PORT}, "users": [{ "id": "${CLIENT_UUID}", "encryption": "none", "flow": "xtls-rprx-vision" }] }] },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "fingerprint": "chrome",
        "serverName": "${REALITY_DEST}",
        "publicKey": "${REALITY_PUBLIC_KEY}",
        "shortId": "${REALITY_SHORT_ID}",
        "spiderX": "/"
      }
    }
  }]
}
EOF
if run_xray_client /tmp/xray-reality-client.json 11083; then
  assert_contains "VLESS+Reality reaches ${TARGET_URL} directly (bypassing Nginx)" "$(fetch_via_socks 11083)" "$MARKER"
fi

echo "--- Hysteria2 direct, including Salamander/finalmask ---" >&2
if [[ ! -x /usr/local/bin/hysteria ]]; then
  curl -fSsL -o /usr/local/bin/hysteria \
    "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64"
  chmod +x /usr/local/bin/hysteria
fi
hysteria_domain="${HYSTERIA_SUBDOMAIN}.${BASE_DOMAIN}"
cat > /tmp/hysteria-client.yaml <<EOF
server: 127.0.0.1:${HYSTERIA_PORT}
auth: ${HYSTERIA_AUTH}
tls:
  sni: ${hysteria_domain}
  insecure: true
obfs:
  type: salamander
  salamander:
    password: ${HYSTERIA_OBFS_PASSWORD}
socks5:
  listen: 127.0.0.1:11084
EOF
/usr/local/bin/hysteria client -c /tmp/hysteria-client.yaml >/tmp/hysteria-client.log 2>&1 &
CLEANUP_PIDS+=("$!")
if wait_for_local_port 11084 tcp; then
  assert_contains "Hysteria2 (Salamander-obfuscated) reaches ${TARGET_URL} directly" \
    "$(fetch_via_socks 11084)" "$MARKER"
else
  fail "hysteria client socks inbound never came up on :11084 (log: $(tail -20 /tmp/hysteria-client.log))"
fi

echo "--- NaiveProxy direct HTTPS forward proxy ---" >&2
naive_domain="${NAIVE_SUBDOMAIN}.${BASE_DOMAIN}"
systemctl is-active --quiet caddy || fail "caddy (NaiveProxy) service is not active"
wait_for_local_port "$NAIVE_PORT" tcp || fail "NaiveProxy is not listening on :${NAIVE_PORT}"
naive_resp="$(curl -sS --max-time 10 \
  --resolve "${naive_domain}:${NAIVE_PORT}:127.0.0.1" \
  --proxy-insecure \
  -x "https://${NAIVE_USERNAME}:${NAIVE_PASSWORD}@${naive_domain}:${NAIVE_PORT}" \
  "$TARGET_URL" 2>/tmp/naive-curl.err || true)"
assert_contains "NaiveProxy forwards a real HTTPS request to ${TARGET_URL}" "$naive_resp" "$MARKER"

echo "--- mieru direct, username/password ---" >&2
mieru_arch="amd64"
if ! command -v mieru >/dev/null 2>&1; then
  mieru_tag="$(curl -sI https://github.com/enfein/mieru/releases/latest \
    | awk -F'/tag/' 'tolower($1) ~ /^location:/ {print $2}' | tr -d '\r')"
  mieru_ver="${mieru_tag#v}"
  curl -fSsL -o /tmp/mieru-client.deb \
    "https://github.com/enfein/mieru/releases/download/${mieru_tag}/mieru_${mieru_ver}_${mieru_arch}.deb"
  dpkg -i /tmp/mieru-client.deb || apt-get install -f -y
fi

# One binding from MIERU_PORTS is enough to prove real end-to-end
# connectivity; the client tries the first listed candidate.
mieru_first_binding="${MIERU_PORTS%%,*}"
mieru_client_port="${mieru_first_binding%%:*}"
mieru_client_proto="${mieru_first_binding#*:}"
cat > /tmp/mieru-client-config.json <<EOF
{
  "profiles": [{
    "profileName": "e2e",
    "servers": [{
      "ipAddress": "127.0.0.1",
      "portBindings": [{ "port": ${mieru_client_port}, "protocol": "${mieru_client_proto}" }]
    }],
    "user": { "name": "${MIERU_USERNAME}", "password": "${MIERU_PASSWORD}" }
  }],
  "activeProfile": "e2e",
  "socks5Port": 11085,
  "loggingLevel": "INFO"
}
EOF
mieru apply config /tmp/mieru-client-config.json
mieru stop >/dev/null 2>&1 || true
mieru start
if wait_for_local_port 11085 tcp; then
  assert_contains "mieru (${mieru_client_proto}/${mieru_client_port}) reaches ${TARGET_URL} directly" \
    "$(fetch_via_socks 11085)" "$MARKER"
else
  fail "mieru client socks5Port never came up on :11085 ($(mieru status 2>&1))"
fi
mieru stop >/dev/null 2>&1 || true

if [[ "$FAIL" -ne 0 ]]; then
  echo >&2
  echo "One or more assertions failed -- see FAIL lines above." >&2
  exit 1
fi

echo >&2
echo "All assertions passed." >&2
