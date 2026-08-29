#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
import socket
import struct
import subprocess
import time

ROOT = pathlib.Path('/opt/nitu-camera-v3')
SOCK = '/run/nitu-camera/godsees.sock'
STATUS = pathlib.Path('/run/nitu-camera-publisher/status.json')


def request(obj: dict) -> dict:
    data = json.dumps(obj, separators=(',', ':')).encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(SOCK)
    s.sendall(struct.pack('!I', len(data)) + data)
    hdr = s.recv(4)
    if len(hdr) != 4:
        raise RuntimeError('short worker response')
    n = struct.unpack('!I', hdr)[0]
    out = bytearray()
    while len(out) < n:
        b = s.recv(n - len(out))
        if not b:
            raise RuntimeError('worker disconnected')
        out.extend(b)
    s.close()
    return json.loads(out.decode())


def active(unit: str) -> None:
    subprocess.run(['systemctl', 'is-active', '--quiet', unit], check=True)


def runtime_status() -> dict | None:
    try:
        return json.loads(STATUS.read_text(encoding='utf-8'))
    except Exception:
        return None


def publisher_health(timeout: float = 20.0) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = request({'op': 'health'})
            if last.get('ok') and int(last.get('publishers') or 0) >= 1:
                return last
        except Exception:
            pass
        time.sleep(0.5)
    status = runtime_status()
    if last is None:
        raise SystemExit(f'GodSees worker health unavailable while waiting for VPN publisher; runtime_status={json.dumps(status, sort_keys=True)}')
    raise SystemExit(
        f"VPN publisher did not register within {timeout:.0f}s; "
        f"worker health={json.dumps(last, sort_keys=True)}; "
        f"runtime_status={json.dumps(status, sort_keys=True)}"
    )


def main() -> int:
    active('nitu-camera-godsees.service')
    active('nitu-camera-godsees-vpn-publisher.service')
    active('wg-quick@nitu360.service')
    active('nitu-camera-gateway.service')
    if not pathlib.Path(SOCK).is_socket():
        raise SystemExit('GodSees Unix socket missing')

    health = publisher_health()
    caps = health.get('capabilities') or {}
    if not caps.get('publisher_ingest') or not caps.get('fastconnect_media_demux'):
        raise SystemExit('GodSees worker publisher/media capabilities missing')

    status = runtime_status()
    if not status or status.get('event') not in {'publisher_registered', 'publisher_stats'}:
        raise SystemExit(f'publisher runtime status not registered: {json.dumps(status, sort_keys=True)}')

    for p in (
        ROOT / 'godsees-worker/godsees_vpn_publisher.py',
        pathlib.Path('/etc/wireguard/nitu360.conf'),
        pathlib.Path('/home/nituadmin/camera360-wireguard.conf'),
        pathlib.Path('/home/nituadmin/camera360-wireguard-README.txt'),
        pathlib.Path('/home/nituadmin/camera360-wireguard.png'),
    ):
        if not p.exists():
            raise SystemExit(f'missing installed artifact: {p}')

    print(json.dumps({
        'ok': True,
        'worker_publishers': health.get('publishers'),
        'publisher_ingest': caps.get('publisher_ingest'),
        'fastconnect_media_demux': caps.get('fastconnect_media_demux'),
        'publisher_runtime': status,
        'android_profile_ready': True,
        'live_media_waiting_for_phone_tunnel': True,
    }, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
