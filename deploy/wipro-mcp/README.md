# Nitu MCP Control Plane v0.2.5 — Wipro Debian combined baseline

This is the deterministic repair/republication of the Wipro package after the incomplete v0.2.4 chunk set was correctly rejected by SHA-256 and ZIP-integrity gates.

## What is combined

v0.2.5 keeps the hardened read-only MCP control plane and adds a versioned, non-secret `project_current_baseline` tool. The baseline records the current project architecture and deployment gates:

- Nitu Unified GT06 Broker with IMEI identity and independent TBTrack + Traccar sinks;
- retired v1.6.x relay / Traccar-mux topology must not be revived;
- telemetry `18083`, v3.1 `18100`, v3.2 `18101`, v3.3 validator `18102`, MobilityDB/PostGIS/H3;
- server-side data age is the transport-freshness authority rather than bad tracker fix time;
- repaired v3.3.1 24-hour soak remains authoritative;
- v3.4a scale-readiness is read-only; v3.4b stays HOLD until official soak PASS;
- Fleet UI baseline is R6.3 True 3D layered over R6.2.2 compact/selected-only tracking;
- Wipro Debian is a portable MCP/control-plane/readiness host, not a destination for Oracle ARM64-only GPS one-click binaries.

`PROJECT_BASELINE.json` is installed read-only to `/etc/nitu-mcp/PROJECT_BASELINE.json` and exposed only through the static `project_current_baseline` MCP tool.

## v0.2.5 runtime and safety

- `mcp==2.0.0`
- `uvicorn==0.35.0`
- `httpx2==2.12.0`
- gateway bind: `127.0.0.1:8780`
- default deny / read-only commissioning
- public MCP upstreams refused
- DNS-name upstreams refused; only localhost or explicit private IP
- no dynamic MCP registration
- no WhatsApp send, arbitrary SQL, unsafe browser JS, generic OCI invoke, restart/start/stop tools
- active LiteLLM must be verifiably `>=1.84.0`
- pre-existing listeners and firewall rules are snapshotted and compared after deployment
- automatic rollback if post-mutation checks fail

## v0.2.5 pre-mutation boot gates

Before replacing the live MCP service, the installer:

1. verifies every inner-file SHA-256 and static policy;
2. resolves the pinned Python environment and runs `pip check`;
3. imports the real gateway with the exact pinned runtime;
4. boots the real gateway with Uvicorn on temporary loopback TCP `18780` and requires `/healthz` PASS;
5. verifies the hardened systemd unit syntax against the staged executable;
6. only then snapshots/mutates the Nitu MCP service state.

If the installed service fails, the rollback bundle captures `systemctl status`, `journalctl`, kernel/systemd version and listeners before restoring the prior MCP state.

## GitHub zero-touch deployment

The production workflow targets only:

`[self-hosted, linux, wipro]`

and is intentionally triggered only by trusted `main` pushes or manual dispatch, never by pull-request code.

Once a Wipro self-hosted runner is registered and online with the `wipro` label, deployment is unattended: outer hash -> safe ZIP extraction -> inner manifest -> validation -> deploy -> live MCP protocol verification -> security audit.

A host with no registered/online GitHub runner cannot execute a GitHub job. Runner registration is a one-time prerequisite outside this bundle; no registration token is stored in this public repository.

## Expected success markers

- `NITU_MCP_WIPRO_V0_2_5_STATIC_VALIDATION_PASS`
- `PINNED_RUNTIME_DEPENDENCIES_PASS`
- `GATEWAY_REAL_RUNTIME_IMPORT_PASS`
- `GATEWAY_PREMUTATION_UVICORN_HEALTH_PASS`
- `SYSTEMD_UNIT_PREMUTATION_VERIFY_PASS`
- `NITU_MCP_V0_2_5_VERIFY_PASS`
- `NITU_MCP_WIPRO_V0_2_5_DEPLOY_PASS`
- `NITU_MCP_WIPRO_V0_2_5_GITHUB_CONTROL_BOOTSTRAP_PASS`
- `NITU_MCP_WIPRO_V0_2_5_GITHUB_RUNNER_DEPLOY_PASS`

No production GPS TCP/NAT/GT06/Traccar mutation is part of this Wipro core package.
