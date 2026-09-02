# Nitu Voice Agent v1 — Gitea-native Wipro server install

Execution plane: local Gitea `nituadmin/nitu-control` on `127.0.0.1:3001`.
Runner: `wipro-production` / `niturunner`.
Foundation gate: Wipro MCP `0.2.8` plus `/usr/local/sbin/nitu-control`.

The bootstrap is intentionally launched once by the Wipro administrator. It installs a narrow sudo rule for only `/usr/local/sbin/nitu-voice-install-root {install|repair|verify}`; it does not grant the Gitea runner blanket sudo.

Asterisk Certified 22.8-cert4 is compiled on the actual Wipro CPU with conservative x86-64/no-AVX flags to avoid the previous Celeron SIGILL failure. The legacy PRoot voice runtime is not used for production.

Server completion requires all of the following:

- Nitu Control health + backup before mutation;
- Wipro MCP 0.2.8 guarded health;
- active pre-existing protected listeners preserved;
- Asterisk 22.8 binary executes on the Wipro CPU;
- `chan_websocket` and `res_websocket_client` loaded;
- voice agent health on `127.0.0.1:8790` with Whisper `base`;
- SIP bound to the Wipro private LAN address on UDP 5060, never wildcard;
- PJSIP endpoint `gateway-gw1` configured (registration is expected to remain unavailable until the phone is installed);
- systemd enable/start and restart persistence pass;
- Gitea and Wipro MCP remain healthy after installation;
- `/opt/nitu-control/voice-v1/state/installed.json` records `server_complete=true` and `phone_pending=true`.

Final success markers:

```
NITU_WIPRO_VOICE_AGENT_V1_INSTALLATION_COMPLETE
NITU_WIPRO_VOICE_AGENT_V1_SERVER_COMPLETE_PHONE_PENDING
```

After those markers, the only remaining deployment step is the rooted Android `gsm2sip` phone. Its local SIP settings are printed with:

```
sudo /usr/local/sbin/nitu-voice-phone-config
```
