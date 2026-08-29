# Nitu MCP Control Plane v0.2.4 — Wipro Debian / GitHub Control

This replaces the failed v0.2.2 Wipro commissioning attempt.

## What the recording established

The v0.2.2 package passed checksum/static/dependency gates, started the installation stage,
but `127.0.0.1:8780` never became reachable. Automatic rollback then removed the failed
gateway unit and helper commands. The recording does not contain the systemd journal, so
v0.2.4 does not guess the missing exception.

## v0.2.4 changes

- Retains MCP 2.0's correct `httpx2` transport and pins `httpx2==2.12.0`.
- Requires `mcp==2.0.0`, `uvicorn==0.35.0`, and `httpx2==2.12.0`.
- Runs `systemd-analyze verify` before mutation.
- Imports the real gateway inside the staged pinned venv before mutation.
- Boots staged Uvicorn on a temporary loopback port and requires `/healthz` PASS before mutation.
- If the installed systemd service fails, captures `systemctl status`, `journalctl`,
  kernel/systemd version and listener state before rollback.
- Preserves the existing listener/firewall equality checks and rollback.
- GitHub CI must boot the hardened systemd service and negotiate the MCP tool catalog before merge.

## Wipro install after GitHub v0.2.4 is merged

```bash
sudo apt-get update && sudo apt-get install -y git unzip ca-certificates python3 && \
rm -rf /tmp/nitu-mcp-bootstrap /tmp/nitu-mcp-package /tmp/nitu-mcp-bundle.* && \
git clone --depth=1 https://github.com/nitutravels/nitu-whatsapp-gateway.git /tmp/nitu-mcp-bootstrap && \
cd /tmp/nitu-mcp-bootstrap/deploy/wipro-mcp && \
cat bundle.part.* > /tmp/nitu-mcp-bundle.b64 && \
base64 -d /tmp/nitu-mcp-bundle.b64 > /tmp/nitu-mcp-bundle.zip && \
echo "$(cat BUNDLE.sha256)  /tmp/nitu-mcp-bundle.zip" | sha256sum -c - && \
mkdir /tmp/nitu-mcp-package && \
unzip -q /tmp/nitu-mcp-bundle.zip -d /tmp/nitu-mcp-package && \
cd /tmp/nitu-mcp-package && \
sha256sum -c SHA256SUMS.txt && \
python3 validate_package.py && \
sudo bash bootstrap_wipro.sh
```

Expected pre-mutation markers include:
- `PINNED_RUNTIME_DEPENDENCIES_PASS`
- `GATEWAY_REAL_RUNTIME_IMPORT_PASS`
- `GATEWAY_PREMUTATION_UVICORN_HEALTH_PASS`

Final success requires:
- `NITU_MCP_V0_2_4_VERIFY_PASS`
- `NITU_MCP_WIPRO_V0_2_4_DEPLOY_PASS`
- `NITU_MCP_WIPRO_V0_2_4_GITHUB_CONTROL_BOOTSTRAP_PASS`

If the installed unit still cannot boot, upload the terminal output. v0.2.4 prints the
captured systemd status/journal before rollback instead of only showing repeated curl errors.
