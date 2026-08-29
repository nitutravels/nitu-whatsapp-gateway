#!/usr/bin/env bash
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run this bootstrap with sudo/root." >&2; exit 2; }
command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
command -v visudo >/dev/null || { echo "sudo/visudo is required" >&2; exit 2; }

HELPER=/usr/local/sbin/nitu-camera-deploy-v5
RULE=/etc/sudoers.d/nitu-camera-deploy-v5
cat >"$HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "$#" -eq 0 ] || { echo "This privileged helper accepts no arguments." >&2; exit 64; }
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
umask 077
ROOT=/opt/nitu-camera-v3
PIN=ba1b8ea9acb0aa0cb458b4f0330358f14538e470
REPO=https://github.com/nitutravels/nitu-whatsapp-gateway.git
[ -d "$ROOT" ] || { echo "Camera V3 is not installed at $ROOT" >&2; exit 2; }
TMP=$(/usr/bin/mktemp -d /root/nitu-camera-v5-deploy.XXXXXX)
cleanup(){ /bin/rm -rf "$TMP"; }
trap cleanup EXIT
/usr/bin/git -c credential.helper= -c core.hooksPath=/dev/null clone --quiet --no-checkout "$REPO" "$TMP/src"
/usr/bin/git -C "$TMP/src" -c credential.helper= fetch --quiet --depth=1 origin "$PIN"
/usr/bin/git -C "$TMP/src" -c core.hooksPath=/dev/null checkout --quiet --detach FETCH_HEAD
ACTUAL=$(/usr/bin/git -C "$TMP/src" rev-parse HEAD)
[ "$ACTUAL" = "$PIN" ] || { echo "Pinned worker source verification failed" >&2; exit 3; }
SRC="$TMP/src/camera-native-v4"
"$ROOT/venv/bin/python" "$SRC/tools/selftest_godsees_worker.py"
/bin/bash "$SRC/tools/install_godsees_worker.sh" "$SRC"
"$ROOT/venv/bin/python" - <<'PY'
import asyncio, json, struct
SOCK='/run/nitu-camera/godsees.sock'
async def rf(r):
    n=struct.unpack('!I', await r.readexactly(4))[0]
    return await r.readexactly(n)
async def sj(w,o):
    b=json.dumps(o,separators=(',',':')).encode()
    w.write(struct.pack('!I',len(b))+b)
    await w.drain()
async def main():
    r,w=await asyncio.open_unix_connection(SOCK)
    await sj(w,{'op':'health'})
    h=json.loads((await rf(r)).decode())
    assert h.get('ok') is True
    w.close(); await w.wait_closed()
    r,w=await asyncio.open_unix_connection(SOCK)
    await sj(w,{'op':'live','camera_id':'security-test','serial_number':'authorized-test',
                'business_token':'','stream_keys':{},'relay_sign':None})
    d=json.loads((await rf(r)).decode())
    assert d.get('ok') is False and d.get('error') == 'AUTHORIZED_SESSION_MATERIAL_MISSING'
    w.close(); await w.wait_closed()
    print('GodSees worker health/fail-closed verification: PASS')
asyncio.run(main())
PY
printf '%s\n' "$PIN" > "$ROOT/GODSEES_WORKER_V5_DEPLOYED_SHA"
/bin/chown root:root "$ROOT/GODSEES_WORKER_V5_DEPLOYED_SHA"
/bin/chmod 0644 "$ROOT/GODSEES_WORKER_V5_DEPLOYED_SHA"
printf '%s\n' "Pinned GodSees worker deployed: $PIN"
EOF
/bin/chown root:root "$HELPER"
/bin/chmod 0755 "$HELPER"

cat >"$RULE" <<EOF
# Narrow GitHub Actions deployment permission for Nitu Camera GodSees worker V5.
# Helper is root-owned, accepts no arguments, and deploys only a pinned commit.
niturunner ALL=(root) NOPASSWD: $HELPER
EOF
/bin/chown root:root "$RULE"
/bin/chmod 0440 "$RULE"
/usr/sbin/visudo -cf "$RULE" >/dev/null
printf '%s\n' \
  "Nitu Camera GodSees worker V5 deployment hook installed." \
  "Allowed command: sudo -n $HELPER" \
  "No blanket passwordless sudo was granted."
