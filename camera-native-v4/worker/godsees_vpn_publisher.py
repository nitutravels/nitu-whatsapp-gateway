#!/usr/bin/env python3
from __future__ import annotations

"""Publish authorized Camera360 FastConnect media seen on a dedicated WireGuard link.

This process does not establish a vendor session, decrypt HTTPS, or create camera
credentials. The Android Camera360 app establishes the authorized session normally;
this publisher only observes the already-authorized FastConnect UDP media records on
Wipro's dedicated VPN interface and forwards those datagrams to the local GodSees
worker over its Unix socket.
"""

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import BinaryIO, Optional

DEFAULT_WORKER_SOCKET = "/run/nitu-camera/godsees.sock"
DEFAULT_INTERFACE = "nitu360"
MAX_FRAME = 8 * 1024 * 1024
RECORD_MAGIC = b"\x20\x14\x11\x04"
MEDIA_MARKERS = {b"\x1d\x00", b"\x1d\x02"}
MEDIA_TYPES = {2, 3, 4}


class PublisherError(RuntimeError):
    pass


def read_exact(stream: BinaryIO, n: int) -> bytes:
    out = bytearray()
    while len(out) < n:
        chunk = stream.read(n - len(out))
        if not chunk:
            raise EOFError
        out.extend(chunk)
    return bytes(out)


def send_frame(sock: socket.socket, data: bytes) -> None:
    if len(data) > MAX_FRAME:
        raise PublisherError("frame too large")
    sock.sendall(struct.pack("!I", len(data)) + data)


def recv_frame(sock: socket.socket) -> bytes:
    hdr = bytearray()
    while len(hdr) < 4:
        chunk = sock.recv(4 - len(hdr))
        if not chunk:
            raise PublisherError("worker disconnected")
        hdr.extend(chunk)
    n = struct.unpack("!I", hdr)[0]
    if n > MAX_FRAME:
        raise PublisherError("worker frame too large")
    out = bytearray()
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise PublisherError("worker disconnected")
        out.extend(chunk)
    return bytes(out)


def connect_worker(path: str, camera_id: str) -> socket.socket:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(path)
    req = json.dumps({"op": "publish", "camera_id": camera_id, "format": "fastconnect-datagram"}, separators=(",", ":")).encode()
    send_frame(s, req)
    ack = json.loads(recv_frame(s).decode())
    if not ack.get("ok"):
        raise PublisherError(str(ack.get("error") or "worker rejected publisher"))
    s.settimeout(None)
    return s


def pcap_header(stream: BinaryIO) -> tuple[str, int]:
    hdr = read_exact(stream, 24)
    magic = hdr[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian = "<"
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian = ">"
    elif magic in {b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d"}:
        endian = "<" if magic == b"\x4d\x3c\xb2\xa1" else ">"
    else:
        raise PublisherError(f"unsupported pcap magic {magic.hex()}")
    linktype = struct.unpack_from(endian + "I", hdr, 20)[0]
    return endian, linktype


def iter_pcap(stream: BinaryIO):
    endian, linktype = pcap_header(stream)
    while True:
        try:
            rec = read_exact(stream, 16)
        except EOFError:
            return
        _ts_s, _ts_frac, incl, _orig = struct.unpack(endian + "IIII", rec)
        if incl > 4 * 1024 * 1024:
            raise PublisherError(f"pcap record too large: {incl}")
        frame = read_exact(stream, incl)
        yield linktype, frame


def ipv4_from_frame(frame: bytes, linktype: int) -> Optional[bytes]:
    if linktype == 1:
        if len(frame) < 14 or frame[12:14] != b"\x08\x00":
            return None
        return frame[14:]
    if linktype in {101, 228}:
        return frame if frame and frame[0] >> 4 == 4 else None
    if linktype == 113:
        if len(frame) < 16 or frame[14:16] != b"\x08\x00":
            return None
        return frame[16:]
    if linktype == 276:
        if len(frame) < 20 or frame[0:2] != b"\x08\x00":
            return None
        return frame[20:]
    if frame and frame[0] >> 4 == 4:
        return frame
    return None


def udp_payload(frame: bytes, linktype: int) -> Optional[tuple[tuple[str, int, str, int], bytes]]:
    ip = ipv4_from_frame(frame, linktype)
    if not ip or len(ip) < 28 or ip[0] >> 4 != 4:
        return None
    ihl = (ip[0] & 0x0F) * 4
    if ihl < 20 or len(ip) < ihl + 8 or ip[9] != socket.IPPROTO_UDP:
        return None
    src = socket.inet_ntoa(ip[12:16])
    dst = socket.inet_ntoa(ip[16:20])
    udp = ip[ihl:]
    src_port, dst_port, udp_len, _checksum = struct.unpack("!HHHH", udp[:8])
    if udp_len < 8:
        return None
    payload = udp[8:min(len(udp), udp_len)]
    return (src, src_port, dst, dst_port), payload


@dataclass
class FlowState:
    remaining: int = 0
    active: bool = False


class AuthorizedMediaFilter:
    """Pass only verified GodSees media starts and their continuation datagrams."""

    def __init__(self) -> None:
        self.flows: dict[tuple[str, int, str, int], FlowState] = {}
        self.forwarded = 0
        self.ignored = 0

    def accept(self, flow: tuple[str, int, str, int], payload: bytes) -> bool:
        if len(payload) < 10 or payload[6:8] not in MEDIA_MARKERS:
            self.ignored += 1
            return False
        state = self.flows.setdefault(flow, FlowState())
        if len(payload) >= 68 and payload[14:18] == RECORD_MAGIC:
            kind = int.from_bytes(payload[18:20], "big")
            declared = int.from_bytes(payload[20:24], "big")
            state.active = kind in MEDIA_TYPES
            state.remaining = max(0, declared - 44) if state.active and declared >= 44 else 0
            if not state.active:
                self.ignored += 1
                return False
            consumed = min(max(len(payload) - 68, 0), state.remaining)
            state.remaining -= consumed
            self.forwarded += 1
            return True
        if state.active and state.remaining > 0:
            consumed = min(max(len(payload) - 10, 0), state.remaining)
            state.remaining -= consumed
            self.forwarded += 1
            return True
        self.ignored += 1
        return False


def start_tcpdump(interface: str) -> subprocess.Popen:
    # WireGuard does not need promiscuous mode. Keeping capture non-promiscuous
    # avoids CAP_NET_ADMIN while the hardened systemd unit grants only CAP_NET_RAW.
    # -Z root prevents tcpdump from trying to switch to the tcpdump account after
    # the service has already been sandboxed with NoNewPrivileges.
    cmd = [
        "/usr/bin/tcpdump", "-i", interface, "-p", "-Z", "root",
        "-nn", "-U", "-s", "0", "-w", "-", "udp", "port", "80",
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    time.sleep(0.25)
    if proc.poll() is not None:
        detail = ""
        if proc.stderr is not None:
            try:
                detail = proc.stderr.read(4096).decode(errors="replace").strip()
            except Exception:
                pass
        raise PublisherError(f"tcpdump failed rc={proc.returncode}: {detail[:300]}")
    return proc


def publish_once(interface: str, worker_socket: str, camera_id: str) -> None:
    # Open capture first so a broken capture path cannot create a misleading
    # short-lived registration in the GodSees worker.
    proc = start_tcpdump(interface)
    assert proc.stdout is not None
    worker: Optional[socket.socket] = None
    filt = AuthorizedMediaFilter()
    last_report = time.monotonic()
    try:
        worker = connect_worker(worker_socket, camera_id)
        print(json.dumps({"event": "publisher_registered", "camera_id": camera_id, "interface": interface}, sort_keys=True), flush=True)
        for linktype, frame in iter_pcap(proc.stdout):
            parsed = udp_payload(frame, linktype)
            if not parsed:
                continue
            flow, payload = parsed
            if not filt.accept(flow, payload):
                continue
            send_frame(worker, payload)
            now = time.monotonic()
            if now - last_report >= 30:
                print(json.dumps({"event": "publisher_stats", "forwarded": filt.forwarded, "ignored": filt.ignored}, sort_keys=True), flush=True)
                last_report = now
        rc = proc.wait(timeout=2)
        detail = ""
        if proc.stderr is not None:
            try:
                detail = proc.stderr.read(4096).decode(errors="replace").strip()
            except Exception:
                pass
        raise PublisherError(f"tcpdump exited rc={rc}: {detail[:300]}")
    finally:
        if worker is not None:
            worker.close()
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()


def self_test() -> None:
    media = bytearray(68 + 12)
    media[6:8] = b"\x1d\x00"
    media[14:18] = RECORD_MAGIC
    media[18:20] = (2).to_bytes(2, "big")
    media[20:24] = (44 + 12).to_bytes(4, "big")
    media[68:80] = b"\x00\x00\x00\x01\x67TEST123"
    udp_len = 8 + len(media)
    ip_len = 20 + udp_len
    ip = bytearray(20)
    ip[0] = 0x45
    ip[2:4] = ip_len.to_bytes(2, "big")
    ip[8] = 64
    ip[9] = socket.IPPROTO_UDP
    ip[12:16] = socket.inet_aton("180.153.233.178")
    ip[16:20] = socket.inet_aton("10.77.0.2")
    udp = struct.pack("!HHHH", 80, 58600, udp_len, 0) + bytes(media)
    parsed = udp_payload(bytes(ip) + udp, 101)
    assert parsed is not None
    flow, payload = parsed
    filt = AuthorizedMediaFilter()
    assert filt.accept(flow, payload)
    cont = bytearray(10 + 8)
    cont[6:8] = b"\x1d\x00"
    assert filt.accept(flow, bytes(cont)) is False
    bad = bytearray(media)
    bad[18:20] = (1).to_bytes(2, "big")
    assert not filt.accept(flow, bytes(bad))
    print("godsees-vpn-publisher self-test: PASS")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--interface", default=os.getenv("GODSEES_VPN_INTERFACE", DEFAULT_INTERFACE))
    ap.add_argument("--worker-socket", default=os.getenv("GODSEES_SOCKET", DEFAULT_WORKER_SOCKET))
    ap.add_argument("--camera-id", default=os.getenv("GODSEES_CAMERA_ID", ""))
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.camera_id:
        print("ERROR: camera id is required", file=sys.stderr)
        return 2
    while True:
        try:
            publish_once(args.interface, args.worker_socket, args.camera_id)
        except KeyboardInterrupt:
            return 130
        except Exception as exc:
            print(json.dumps({"event": "publisher_restart", "error": type(exc).__name__, "detail": str(exc)[:400]}, sort_keys=True), file=sys.stderr, flush=True)
            time.sleep(3)


if __name__ == "__main__":
    raise SystemExit(main())
