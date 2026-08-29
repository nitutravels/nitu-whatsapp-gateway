#!/usr/bin/env bash
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run this bootstrap with sudo/root." >&2; exit 2; }
command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
command -v visudo >/dev/null || { echo "sudo/visudo is required" >&2; exit 2; }

HELPER=/usr/local/sbin/nitu-camera-deploy-v6
RULE=/etc/sudoers.d/nitu-camera-deploy-v6
cat >"$HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "$#" -eq 0 ] || { echo "This privileged helper accepts no arguments." >&2; exit 64; }
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
umask 077
ROOT=/opt/nitu-camera-v3
PIN=5bd2f57cb57b723bdab1ebae3ec6d2eea36693bc
REPO=https://github.com/nitutravels/nitu-whatsapp-gateway.git
[ -d "$ROOT" ] || { echo "Camera V3 is not installed at $ROOT" >&2; exit 2; }
[ -S /run/nitu-camera/godsees.sock ] || { echo "GodSees V5 worker is not active" >&2; exit 2; }
TMP=$(/usr/bin/mktemp -d /root/nitu-camera-v6-deploy.XXXXXX)
cleanup(){ /bin/rm -rf "$TMP"; }
trap cleanup EXIT
/usr/bin/git -c credential.helper= -c core.hooksPath=/dev/null clone --quiet --no-checkout "$REPO" "$TMP/src"
/usr/bin/git -C "$TMP/src" -c credential.helper= fetch --quiet --depth=1 origin "$PIN"
/usr/bin/git -C "$TMP/src" -c core.hooksPath=/dev/null checkout --quiet --detach FETCH_HEAD
ACTUAL=$(/usr/bin/git -C "$TMP/src" rev-parse HEAD)
[ "$ACTUAL" = "$PIN" ] || { echo "Pinned publisher source verification failed" >&2; exit 3; }
SRC="$TMP/src/camera-native-v4"
/bin/bash -n "$SRC/tools/install_godsees_vpn_publisher.sh"
"$ROOT/venv/bin/python" -m py_compile "$SRC/worker/godsees_vpn_publisher.py" "$SRC/tools/verify_godsees_vpn_publisher.py"
"$ROOT/venv/bin/python" "$SRC/worker/godsees_vpn_publisher.py" --self-test
/bin/bash "$SRC/tools/install_godsees_vpn_publisher.sh" "$SRC"
"$ROOT/venv/bin/python" "$SRC/tools/verify_godsees_vpn_publisher.py"
printf '%s\n' "$PIN" > "$ROOT/GODSEES_VPN_PUBLISHER_V6_DEPLOYED_SHA"
/bin/chown root:root "$ROOT/GODSEES_VPN_PUBLISHER_V6_DEPLOYED_SHA"
/bin/chmod 0644 "$ROOT/GODSEES_VPN_PUBLISHER_V6_DEPLOYED_SHA"
printf '%s\n' "Pinned Camera360 VPN publisher deployed: $PIN"
EOF
/bin/chown root:root "$HELPER"
/bin/chmod 0755 "$HELPER"

cat >"$RULE" <<EOF
# Narrow GitHub Actions deployment permission for Nitu Camera360 publisher V6.
# Helper is root-owned, accepts no arguments, and deploys only a pinned commit.
niturunner ALL=(root) NOPASSWD: $HELPER
EOF
/bin/chown root:root "$RULE"
/bin/chmod 0440 "$RULE"
/usr/sbin/visudo -cf "$RULE" >/dev/null
printf '%s\n' \
  "Nitu Camera360 VPN publisher V6 deployment hook installed." \
  "Allowed command: sudo -n $HELPER" \
  "No blanket passwordless sudo was granted."
