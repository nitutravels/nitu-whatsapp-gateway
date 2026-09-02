#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

VOICE_VERSION='1.0.0-gitea-native'
AST_VERSION='22.8-cert4'
AST_URL_BASE='https://downloads.asterisk.org/pub/telephony/certified-asterisk/releases'
ROOT='/opt/nitu-control/voice-v1'
SRC_ROOT='/opt/nitu-control/deploy/voice-v1'
BUILD='/var/tmp/nitu-voice-asterisk-build'
AST_PREFIX="$ROOT/asterisk"
ETC="$ROOT/etc/asterisk"
VAR="$ROOT/var"
RUN="$ROOT/run"
LOG="$ROOT/logs"
CACHE="$ROOT/cache"
VENV="$ROOT/venv"
SECURE="$ROOT/secure"
STATE="$ROOT/state"
AGENT_SRC="$SRC_ROOT/agent.py"
PROTECTED_PORTS=(80 443 3001 5023 15023 16023 8781)

log(){ printf '[nitu-voice] %s\n' "$*"; }
die(){ printf '[nitu-voice] ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
active_listener(){ local p="$1"; ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${p}$"; }

[[ "$(hostname)" == 'nitu-server' ]] || die "wrong host: $(hostname)"
[[ "$(uname -m)" == 'x86_64' ]] || die "unsupported architecture: $(uname -m)"
[[ -r /etc/os-release ]] || die '/etc/os-release missing'
. /etc/os-release
[[ "$ID" == 'debian' ]] || die "expected Debian, got ${ID:-unknown}"
[[ "$(id -un)" == 'niturunner' ]] || die "Gitea production job must run as niturunner, got $(id -un)"
need sudo; need curl; need python3; need sha256sum; need ss; need systemctl
sudo -n true || die 'passwordless fixed production sudo is unavailable'
sudo -n systemctl is-active --quiet gitea || die 'gitea service is not active'
sudo -n systemctl is-active --quiet gitea-runner || die 'gitea-runner service is not active'

log 'verify Wipro MCP v0.2.8 guarded foundation'
MCP_JSON="$(curl -fsS --max-time 5 http://127.0.0.1:8781/healthz)" || die 'Wipro MCP health unavailable'
printf '%s' "$MCP_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True; assert d.get("version")=="0.2.8"; assert d.get("mode")=="read_write_guarded_rootless"; assert d.get("protected_gps_ports")==[5023,15023,16023]'
sudo -n /usr/local/sbin/nitu-control health || die 'Nitu Control health failed'
sudo -n /usr/local/sbin/nitu-control backup-now || die 'Nitu Control backup failed'

sudo install -d -m 0755 -o niturunner -g niturunner "$SRC_ROOT" "$ROOT" "$STATE"
[[ -s "$AGENT_SRC" ]] || die "agent source missing: $AGENT_SRC"
python3 -m py_compile "$AGENT_SRC"

BEFORE="$STATE/protected-before.txt"
: > "$BEFORE"
for p in "${PROTECTED_PORTS[@]}"; do
  if active_listener "$p"; then echo "$p" >> "$BEFORE"; fi
done
log "protected listeners before: $(tr '\n' ' ' < "$BEFORE")"

FREE_KB="$(df -Pk /opt | awk 'NR==2{print $4}')"
(( FREE_KB >= 4194304 )) || die 'less than 4 GiB free on /opt'
MEM_KB="$(awk '/MemAvailable:/{print $2}' /proc/meminfo)"
(( MEM_KB >= 1048576 )) || die 'less than 1 GiB available RAM'

sudo systemctl disable --now nitu-voice-asterisk.service nitu-voice-agent.service 2>/dev/null || true
pkill -u niturunner -f '/\.local/share/nitu-voice-v1/' 2>/dev/null || true
TMP_CRON="$(mktemp)"; trap 'rm -f "$TMP_CRON"' EXIT
crontab -l 2>/dev/null | sed '/# NITU_VOICE_V1_BEGIN/,/# NITU_VOICE_V1_END/d' > "$TMP_CRON" || true
crontab "$TMP_CRON" || true

log 'install fixed build/runtime dependencies'
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl build-essential pkg-config bison flex git patch tar gzip xz-utils \
  python3 python3-venv python3-pip ffmpeg espeak-ng \
  libssl-dev libxml2-dev libsqlite3-dev uuid-dev libjansson-dev libedit-dev \
  libncurses-dev libnewt-dev libcurl4-openssl-dev libspeex-dev libspeexdsp-dev \
  libogg-dev libvorbis-dev libasound2-dev libsrtp2-dev libopus-dev libgsm1-dev \
  liburiparser-dev libcap-dev

for c in gcc g++ make pkg-config bison flex curl python3 ffmpeg espeak-ng; do need "$c"; done

if ! id nituvoice >/dev/null 2>&1; then
  sudo useradd --system --home-dir "$ROOT" --shell /usr/sbin/nologin nituvoice
fi

REBUILD=1
if [[ -x "$AST_PREFIX/sbin/asterisk" && -f "$STATE/installed.json" ]]; then
  if "$AST_PREFIX/sbin/asterisk" -V 2>/dev/null | grep -q '22.8'; then
    REBUILD=0
  fi
fi

if (( REBUILD )); then
  log 'build Certified Asterisk on the actual Wipro Celeron CPU'
  sudo rm -rf "$BUILD"
  sudo install -d -m 0755 -o niturunner -g niturunner "$BUILD"
  cd "$BUILD"
  curl -fL --retry 4 --retry-delay 3 -O "$AST_URL_BASE/asterisk-certified-${AST_VERSION}.tar.gz"
  curl -fL --retry 4 --retry-delay 3 -O "$AST_URL_BASE/asterisk-certified-${AST_VERSION}.sha256"
  sha256sum -c "asterisk-certified-${AST_VERSION}.sha256"
  tar --no-same-owner -xzf "asterisk-certified-${AST_VERSION}.tar.gz"
  SRC_DIR="$(find "$BUILD" -mindepth 1 -maxdepth 1 -type d -name '*22.8*cert4*' -print -quit)"
  [[ -n "$SRC_DIR" && -x "$SRC_DIR/configure" ]] || die 'Asterisk source directory not found after extraction'
  cd "$SRC_DIR"
  export CFLAGS='-O2 -pipe -march=x86-64 -mtune=generic -mno-avx -mno-avx2 -mno-fma -fno-tree-vectorize'
  export CXXFLAGS="$CFLAGS"
  export MAKEFLAGS='-j1'
  ./configure \
    --prefix="$AST_PREFIX" \
    --sysconfdir="$ETC" \
    --localstatedir="$VAR" \
    --with-pjproject-bundled \
    --with-jansson-bundled
  make menuselect.makeopts
  menuselect/menuselect \
    --enable chan_websocket \
    --enable res_websocket_client \
    --enable chan_pjsip \
    --enable res_pjsip \
    menuselect.makeopts
  make -j1
  sudo make install
  [[ -x "$AST_PREFIX/sbin/asterisk" ]] || die 'Asterisk binary missing after install'
  "$AST_PREFIX/sbin/asterisk" -V | grep -q '22.8' || die 'Asterisk version check failed / CPU incompatibility'
  [[ -s "$AST_PREFIX/lib/asterisk/modules/chan_websocket.so" ]] || die 'chan_websocket module missing'
  [[ -s "$AST_PREFIX/lib/asterisk/modules/res_websocket_client.so" ]] || die 'res_websocket_client module missing'
fi

log 'create isolated voice runtime'
sudo install -d -m 0750 -o nituvoice -g nituvoice "$ROOT"
sudo install -d -m 0750 -o nituvoice -g nituvoice \
  "$ETC" "$VAR/lib/asterisk" "$VAR/spool/asterisk" "$RUN/asterisk" \
  "$LOG/asterisk" "$CACHE" "$SECURE" "$ROOT/app" "$STATE"
sudo install -m 0755 -o nituvoice -g nituvoice "$AGENT_SRC" "$ROOT/app/agent.py"

if [[ ! -x "$VENV/bin/python" ]]; then
  sudo -u nituvoice python3 -m venv "$VENV"
fi
sudo -u nituvoice "$VENV/bin/pip" install --disable-pip-version-check --no-cache-dir --upgrade pip wheel
sudo -u nituvoice "$VENV/bin/pip" install --disable-pip-version-check --no-cache-dir 'aiohttp==3.12.15' 'faster-whisper==1.2.1'

log 'preload Whisper base model under service identity'
sudo -u nituvoice env HF_HOME="$CACHE" "$VENV/bin/python" - <<'PY'
from faster_whisper import WhisperModel
WhisperModel('base', device='cpu', compute_type='int8')
print('WHISPER_BASE_PRELOAD_PASS')
PY

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
[[ "$LAN_IP" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]] || die "refusing non-private SIP bind address: ${LAN_IP:-missing}"
SIP_USER='gw1'
SIP_SECRET_FILE="$SECURE/gsm2sip.secret"
if [[ ! -s "$SIP_SECRET_FILE" ]]; then
  python3 - <<'PY' | sudo tee "$SIP_SECRET_FILE" >/dev/null
import secrets
print(secrets.token_urlsafe(30))
PY
  sudo chmod 0600 "$SIP_SECRET_FILE"
  sudo chown root:root "$SIP_SECRET_FILE"
fi
SIP_SECRET="$(sudo cat "$SIP_SECRET_FILE")"

sudo tee "$ROOT/etc/voice.env" >/dev/null <<EOF_ENV
VOICE_BIND=127.0.0.1
VOICE_PORT=8790
WHISPER_MODEL=base
HF_HOME=$CACHE
LOG_LEVEL=INFO
NITU_AGENT_BACKEND_URL=
NITU_AGENT_BACKEND_TOKEN=
OLLAMA_URL=http://127.0.0.1:11434
OLLAMA_MODEL=qwen2.5:3b
EOF_ENV
sudo chmod 0640 "$ROOT/etc/voice.env"
sudo chown root:nituvoice "$ROOT/etc/voice.env"

sudo tee "$ETC/asterisk.conf" >/dev/null <<EOF_AST
[directories]
astetcdir => $ETC
astmoddir => $AST_PREFIX/lib/asterisk/modules
astvarlibdir => $VAR/lib/asterisk
astdbdir => $VAR/lib/asterisk
astkeydir => $VAR/lib/asterisk
astdatadir => $VAR/lib/asterisk
astagidir => $VAR/lib/asterisk/agi-bin
astspooldir => $VAR/spool/asterisk
astrundir => $RUN/asterisk
astlogdir => $LOG/asterisk
astsbindir => $AST_PREFIX/sbin
[options]
runuser = nituvoice
rungroup = nituvoice
systemname = nitu-wipro-voice
EOF_AST

sudo tee "$ETC/modules.conf" >/dev/null <<'EOF_MOD'
[modules]
autoload=yes
EOF_MOD
sudo tee "$ETC/logger.conf" >/dev/null <<'EOF_LOG'
[general]
[logfiles]
console => notice,warning,error
messages => notice,warning,error
EOF_LOG
sudo tee "$ETC/rtp.conf" >/dev/null <<'EOF_RTP'
[general]
rtpstart=10000
rtpend=10100
strictrtp=yes
EOF_RTP
sudo tee "$ETC/websocket_client.conf" >/dev/null <<'EOF_WS'
[nitu_voice]
type=websocket_client
uri=ws://127.0.0.1:8790/media
protocols=media
connection_type=per_call_config
EOF_WS
sudo tee "$ETC/chan_websocket.conf" >/dev/null <<'EOF_CWS'
[general]
EOF_CWS
sudo tee "$ETC/pjsip.conf" >/dev/null <<EOF_PJSIP
[global]
type=global
user_agent=Nitu-Wipro-Voice/1.0

[transport-udp]
type=transport
protocol=udp
bind=$LAN_IP:5060

[gateway-gw1]
type=endpoint
transport=transport-udp
context=from-gsm
disallow=all
allow=alaw,ulaw
auth=gateway-gw1
aors=gateway-gw1
direct_media=no
rewrite_contact=yes
rtp_symmetric=yes
force_rport=yes

[gateway-gw1]
type=auth
auth_type=userpass
username=$SIP_USER
password=$SIP_SECRET

[gateway-gw1]
type=aor
max_contacts=1
remove_existing=yes
qualify_frequency=30
EOF_PJSIP
sudo chmod 0640 "$ETC/pjsip.conf"
sudo chown root:nituvoice "$ETC/pjsip.conf"

sudo tee "$ETC/extensions.conf" >/dev/null <<'EOF_EXT'
[general]
static=yes
writeprotect=yes

[from-gsm]
exten => _X.,1,NoOp(Nitu GSM inbound caller=${CALLERID(num)} called=${EXTEN})
 same => n,Dial(WebSocket/nitu_voice/c(slin16)f(json)v(direction=inbound,caller=${CALLERID(num)},called=${EXTEN}),120)
 same => n,Hangup()
exten => s,1,NoOp(Nitu GSM inbound caller=${CALLERID(num)})
 same => n,Dial(WebSocket/nitu_voice/c(slin16)f(json)v(direction=inbound,caller=${CALLERID(num)},called=s),120)
 same => n,Hangup()

[nitu-outbound]
exten => _X.,1,NoOp(Nitu GSM outbound ${EXTEN})
 same => n,Dial(PJSIP/gateway-gw1,60,b(set-gsm-forward^s^1(${EXTEN})))
 same => n,Hangup()

[set-gsm-forward]
exten => s,1,Set(PJSIP_HEADER(add,X-GSM-Forward)=+${ARG1})
 same => n,Return()
EOF_EXT

sudo chown -R nituvoice:nituvoice "$VAR" "$RUN" "$LOG" "$CACHE" "$ROOT/app" "$VENV"
sudo chmod 0750 "$SECURE"

sudo tee /etc/systemd/system/nitu-voice-agent.service >/dev/null <<EOF_SVC
[Unit]
Description=Nitu Voice Agent v1
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nituvoice
Group=nituvoice
WorkingDirectory=$ROOT/app
EnvironmentFile=$ROOT/etc/voice.env
ExecStart=$VENV/bin/python $ROOT/app/agent.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ROOT

[Install]
WantedBy=multi-user.target
EOF_SVC

sudo tee /etc/systemd/system/nitu-voice-asterisk.service >/dev/null <<EOF_SVC
[Unit]
Description=Nitu Asterisk 22.8 Voice Gateway
After=network-online.target nitu-voice-agent.service
Wants=network-online.target
Requires=nitu-voice-agent.service

[Service]
Type=simple
User=nituvoice
Group=nituvoice
WorkingDirectory=$ROOT
ExecStart=$AST_PREFIX/sbin/asterisk -f -C $ETC/asterisk.conf
ExecReload=$AST_PREFIX/sbin/asterisk -C $ETC/asterisk.conf -rx 'core reload'
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ROOT

[Install]
WantedBy=multi-user.target
EOF_SVC

sudo tee /usr/local/sbin/nitu-voice-server-status >/dev/null <<EOF_STATUS
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT='$ROOT'
AST='$AST_PREFIX/sbin/asterisk'
CONF='$ETC/asterisk.conf'
LAN_IP='$LAN_IP'
verify=0
[[ "\${1:-}" == '--verify' ]] && verify=1
systemctl is-active nitu-voice-agent.service
systemctl is-active nitu-voice-asterisk.service
curl -fsS --max-time 5 http://127.0.0.1:8790/health | python3 -m json.tool
"\$AST" -C "\$CONF" -rx 'module show like chan_websocket'
"\$AST" -C "\$CONF" -rx 'module show like res_websocket_client'
"\$AST" -C "\$CONF" -rx 'pjsip show endpoint gateway-gw1' | sed -n '1,80p'
ss -H -lun | awk '{print \$5}' | grep -Fx "\$LAN_IP:5060"
! ss -H -lun | awk '{print \$5}' | grep -Eq '^(0\.0\.0\.0|\[::\]|\*):5060$'
curl -fsS --max-time 5 http://127.0.0.1:8781/healthz | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d.get("version")=="0.2.8" and d.get("ok") is True'
if (( verify )); then echo NITU_WIPRO_VOICE_SERVER_VERIFY_PASS; fi
EOF_STATUS
sudo chmod 0755 /usr/local/sbin/nitu-voice-server-status

sudo tee /usr/local/sbin/nitu-voice-phone-config >/dev/null <<EOF_PHONE
#!/usr/bin/env bash
set -Eeuo pipefail
SECRET="\$(cat '$SIP_SECRET_FILE')"
cat <<CFG
NITU_VOICE_PHONE_SETUP
SIP_SERVER=$LAN_IP
SIP_PORT=5060
SIP_TRANSPORT=UDP
SIP_USERNAME=$SIP_USER
SIP_PASSWORD=\$SECRET
PREFERRED_CODEC=G722_OR_ALAW
PHONE_STATUS=PENDING_ANDROID_GSM2SIP
CFG
EOF_PHONE
sudo chmod 0700 /usr/local/sbin/nitu-voice-phone-config

sudo systemctl daemon-reload
sudo systemctl enable --now nitu-voice-agent.service
for i in $(seq 1 90); do
  if curl -fsS --max-time 3 http://127.0.0.1:8790/health >/tmp/nitu-voice-health.json 2>/dev/null; then break; fi
  sleep 2
done
python3 - <<'PY'
import json
h=json.load(open('/tmp/nitu-voice-health.json'))
assert h.get('ok') is True, h
assert h.get('whisper_model') == 'base', h
print('NITU_VOICE_AGENT_HEALTH_PASS')
PY
sudo systemctl enable --now nitu-voice-asterisk.service
for i in $(seq 1 60); do
  if sudo systemctl is-active --quiet nitu-voice-asterisk.service; then
    if ss -H -lun | awk '{print $5}' | grep -Fx "$LAN_IP:5060" >/dev/null; then break; fi
  fi
  sleep 2
done

sudo /usr/local/sbin/nitu-voice-server-status --verify
sudo systemctl restart nitu-voice-agent.service
for i in $(seq 1 60); do curl -fsS --max-time 3 http://127.0.0.1:8790/health >/dev/null 2>&1 && break; sleep 2; done
sudo systemctl restart nitu-voice-asterisk.service
sleep 5
sudo /usr/local/sbin/nitu-voice-server-status --verify
sudo systemctl is-enabled --quiet nitu-voice-agent.service
sudo systemctl is-enabled --quiet nitu-voice-asterisk.service

while read -r p; do
  [[ -n "$p" ]] || continue
  active_listener "$p" || die "protected listener $p disappeared during voice install"
done < "$BEFORE"
sudo -n /usr/local/sbin/nitu-control health || die 'Nitu Control health failed after install'
curl -fsS --max-time 5 http://127.0.0.1:8781/healthz >/dev/null
sudo systemctl is-active --quiet gitea
sudo systemctl is-active --quiet gitea-runner

AST_VER="$($AST_PREFIX/sbin/asterisk -V | tr -d '\r')"
BUNDLE_SHA="$(sha256sum "$AGENT_SRC" | awk '{print $1}')"
NOW="$(date -u +%FT%TZ)"
sudo tee "$STATE/installed.json" >/dev/null <<EOF_STATE
{"version":"$VOICE_VERSION","asterisk":"$AST_VER","lan_ip":"$LAN_IP","sip_port":5060,"agent_health":"http://127.0.0.1:8790/health","mcp_version":"0.2.8","gitea_repo":"nituadmin/nitu-control","runner":"wipro-production","agent_sha256":"$BUNDLE_SHA","installed_utc":"$NOW","server_complete":true,"phone_pending":true}
EOF_STATE
sudo chmod 0644 "$STATE/installed.json"
sudo install -d -m 0755 /opt/nitu-control/receipts
sudo cp "$STATE/installed.json" /opt/nitu-control/receipts/nitu-voice-v1-server-complete.json

log 'SERVER COMPLETE: Android gsm2sip phone is the only remaining deployment step'
echo NITU_WIPRO_VOICE_AGENT_V1_SERVER_COMPLETE_PHONE_PENDING
