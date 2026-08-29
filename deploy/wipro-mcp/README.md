# Nitu MCP v0.2.2 — Wipro Debian GitHub Control

This directory publishes the verified Nitu MCP Control Plane bundle for the Wipro Debian server.

## Safety model

- GitHub stores the release as deterministic base64 chunks plus an independent decoded-ZIP SHA-256.
- Wipro concatenates and decodes the chunks, verifies `BUNDLE.sha256`, rejects unsafe ZIP paths/symlinks, verifies the bundle's internal `SHA256SUMS.txt`, and runs `validate_package.py` before deployment.
- The gateway binds to `127.0.0.1:8780` only and exposes a read-only tool catalog.
- Dynamic MCP registration, arbitrary SQL, WAHA send/admin, Playwright unsafe JavaScript, generic OCI invoke, and model-selected upstream URLs are denied.
- Any active LiteLLM must be verifiably >= 1.84.0.
- An unexpected child process under the MCP gateway causes the gateway to stop and records a security alert.
- Existing listeners and firewall state are compared before/after deployment; post-mutation failure triggers rollback.

## One-time bootstrap on Wipro Debian

```bash
sudo apt-get update && sudo apt-get install -y git unzip ca-certificates python3 && \
rm -rf /tmp/nitu-mcp-bootstrap /tmp/nitu-mcp-package /tmp/nitu-mcp-bundle.* && \
git clone --depth=1 https://github.com/nitutravels/nitu-whatsapp-gateway.git /tmp/nitu-mcp-bootstrap && \
cd /tmp/nitu-mcp-bootstrap/deploy/wipro-mcp && \
cat bundle.part.* > /tmp/nitu-mcp-bundle.b64 && \
base64 -d /tmp/nitu-mcp-bundle.b64 > /tmp/nitu-mcp-bundle.zip && \
echo "$(cat BUNDLE.sha256)  /tmp/nitu-mcp-bundle.zip" | sha256sum -c - && \
mkdir /tmp/nitu-mcp-package && unzip -q /tmp/nitu-mcp-bundle.zip -d /tmp/nitu-mcp-package && \
cd /tmp/nitu-mcp-package && sha256sum -c SHA256SUMS.txt && \
python3 validate_package.py && sudo bash bootstrap_wipro.sh
```

After bootstrap, `nitu-mcp-github-sync.timer` checks GitHub about every 15 minutes and only deploys when the verified bundle hash changes. Change `AUTO_DEPLOY` to `HOLD` to freeze GitHub-driven updates without stopping the currently running gateway.

## Verify on Wipro

```bash
sudo systemctl status nitu-mcp-gateway --no-pager
sudo nitu-mcp-verify --require-pass
sudo nitu-mcp-security-audit
sudo systemctl list-timers 'nitu-mcp-*'
curl -fsS http://127.0.0.1:8780/healthz
```

Expected first-install success markers include `NITU_MCP_WIPRO_V0_2_2_DEPLOY_PASS` and `NITU_MCP_WIPRO_GITHUB_CONTROL_BOOTSTRAP_PASS`.
