# Nitu MCP Control Plane v0.2.3 — Wipro Debian / GitHub Control

This is the Wipro Debian commissioning build of the Nitu-owned MCP gateway.

Critical v0.2.3 repair:
- Fixes the failed v0.2.2 Wipro bootstrap seen in the Termux recording.
- Root cause: `gateway.py` imported nonexistent `httpx2`; the service crashed before port 8780 could open.
- `httpx==0.28.1` is now explicit and the staged venv must successfully `import gateway` before any mutation begins.
- GitHub Actions also performs a real dependency install + gateway runtime import.

Changes from v0.2.1:
- Debian-aware preflight and resource gates.
- GitHub desired-state control from `nitutravels/nitu-whatsapp-gateway` → `deploy/wipro-mcp`.
- 15-minute manifest-verified update timer.
- Active LiteLLM gate: any active LiteLLM must be verifiably >= 1.84.0.
- Unexpected child-process guard: stop the gateway and alert if it spawns a child.
- Stronger systemd sandboxing with 768 MiB memory and 128-task caps.
- Existing listeners/firewall are checked before and after deployment.
- WAHA, Fleet, Google Ads, MySQL and OCI upstreams remain disabled until separately commissioned.

First Wipro install after the GitHub release folder is merged to main:

```bash
sudo apt-get update && sudo apt-get install -y git unzip ca-certificates python3 && \
rm -rf /tmp/nitu-mcp-bootstrap && \
git clone --depth=1 https://github.com/nitutravels/nitu-whatsapp-gateway.git /tmp/nitu-mcp-bootstrap && \
cd /tmp/nitu-mcp-bootstrap/deploy/wipro-mcp && \
cat bundle.part.* > /tmp/nitu-mcp-bundle.b64 && \
base64 -d /tmp/nitu-mcp-bundle.b64 > /tmp/nitu-mcp-bundle.zip && \
echo "$(cat BUNDLE.sha256)  /tmp/nitu-mcp-bundle.zip" | sha256sum -c - && \
rm -rf /tmp/nitu-mcp-package && mkdir /tmp/nitu-mcp-package && \
unzip -q /tmp/nitu-mcp-bundle.zip -d /tmp/nitu-mcp-package && \
cd /tmp/nitu-mcp-package && \
sha256sum -c SHA256SUMS.txt && \
python3 validate_package.py && \
sudo bash bootstrap_wipro.sh
```

Verify:
```bash
sudo systemctl status nitu-mcp-gateway --no-pager
sudo nitu-mcp-verify --require-pass
sudo nitu-mcp-security-audit
sudo systemctl list-timers 'nitu-mcp-*'
curl -fsS http://127.0.0.1:8780/healthz
```

Future GitHub updates are pulled by `nitu-mcp-github-sync.timer`.
Set `AUTO_DEPLOY` to `HOLD` in GitHub to freeze automatic deployment while keeping the current gateway running.
