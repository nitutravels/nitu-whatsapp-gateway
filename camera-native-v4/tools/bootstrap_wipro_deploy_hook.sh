#!/usr/bin/env bash
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run this bootstrap with sudo/root." >&2; exit 2; }
command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
command -v visudo >/dev/null || { echo "sudo/visudo is required" >&2; exit 2; }

HELPER=/usr/local/sbin/nitu-camera-deploy-v4
RULE=/etc/sudoers.d/nitu-camera-deploy-v4
cat >"$HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "$#" -eq 0 ] || { echo "This privileged helper accepts no arguments." >&2; exit 64; }
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
umask 077
ROOT=/opt/nitu-camera-v3
PIN=9e9d1972df49b978fb22f3302c37e1d9484763f7
REPO=https://github.com/nitutravels/nitu-whatsapp-gateway.git
[ -d "$ROOT" ] || { echo "V3 is not installed at $ROOT" >&2; exit 2; }
TMP=$(/usr/bin/mktemp -d /root/nitu-camera-v4-deploy.XXXXXX)
cleanup(){ /bin/rm -rf "$TMP"; }
trap cleanup EXIT
/usr/bin/git -c credential.helper= -c core.hooksPath=/dev/null clone --quiet --no-checkout "$REPO" "$TMP/src"
/usr/bin/git -C "$TMP/src" -c credential.helper= fetch --quiet --depth=1 origin "$PIN"
/usr/bin/git -C "$TMP/src" -c core.hooksPath=/dev/null checkout --quiet --detach FETCH_HEAD
ACTUAL=$(/usr/bin/git -C "$TMP/src" rev-parse HEAD)
[ "$ACTUAL" = "$PIN" ] || { echo "Pinned decoder source verification failed" >&2; exit 3; }
SRC="$TMP/src/camera-native-v4"
"$ROOT/venv/bin/python" "$SRC/tools/selftest_decoder_v4.py"
/bin/bash "$SRC/tools/install_decoder_v4.sh" "$SRC"
printf '%s\n' "$PIN" > "$ROOT/DECODER_V4_DEPLOYED_SHA"
/bin/chown nitu-camera:nitu-camera "$ROOT/DECODER_V4_DEPLOYED_SHA" 2>/dev/null || true
printf '%s\n' "Pinned decoder V4 deployed: $PIN"
EOF
/bin/chown root:root "$HELPER"
/bin/chmod 0755 "$HELPER"

cat >"$RULE" <<EOF
# Narrow GitHub Actions deployment permission for Nitu Camera V4.
# The helper is root-owned, accepts no arguments, and deploys only a pinned commit.
niturunner ALL=(root) NOPASSWD: $HELPER
EOF
/bin/chown root:root "$RULE"
/bin/chmod 0440 "$RULE"
/usr/sbin/visudo -cf "$RULE" >/dev/null
printf '%s\n' \
  "Nitu Camera V4 GitHub deployment hook installed." \
  "Allowed command: sudo -n $HELPER" \
  "No blanket passwordless sudo was granted."
