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
import sys
import time
from dataclasses import dataclass
from typing import Optional

DEFAULT_WORKER_SOCKET = "/run/nitu-camera/godsees.sock"
DEFAULT_INTERFACE = "nitu360"
DEFAULT_STATUS = "/run/nitu-camera-godsees-vpn-publisher.status.json"
MAX_FRAME = 8 * 1024 * 1024
RECORD_MAGIC = b"\x20\x14\x11\x04"
MEDIA_MARKERS = {b"\x1d\x00", b"\x1d\x02"}
MEDIA_TYPES = {2, 3, 4}
ETH_P_ALL_FALLBACK = 0x0003


class PublisherError(RuntimeError):
    pass


def write_status(event: str, **fields: object) -> None:
    path = os.getenv("GODSEES_PUBLISHER_STATUS", DEFAULT_STATUS)
    payload = {
        "event": event,
        "pid": os.getpid(),
        "time": int(time.time()),
        **fields,
    }
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, sort_keys=True, separators=(",", ":"))
            f.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


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
    req = json.dumps(
        {"op": "publish", "camera_id": camera_id, "format": "fastconnect-datagram"},
        separators=(",", ":"),
    ).encode()
    send_frame(s, req)
    ack = json.loads(recv_frame(s).decode())
    if not ack.get("ok"):
        raise PublisherError(str(ack.get("error") or "worker rejected publisher"))
    s.settimeout(None)
    return s


def ipv4_udp_payload(ip: bytes) -> Optional[tuple[tuple[str, int, str, int], bytes]]:
    if len(ip) < 28 or ip[0] >> 4 != 4:
        return None
    ihl = (ip[0] & 0x0F) * 4
    if ihl < 20 or len(ip) < ihl + 8 or ip[9] != socket.IPPROTO_UDP:
        return None
    total_len = int.from_bytes(ip[2:4], "big")
    if total_len >= ihl + 8:
        ip = ip[: min(len(ip), total_len)]
    src = socket.inet_ntoa(ip[12:16])
    dst = socket.inet_ntoa(ip[16:20])
    udp = ip[ihl:]
    src_port, dst_port, udp_len, _checksum = struct.unpack("!HHHH", udp[:8])
    if udp_len < 8:
        return None
    payload = udp[8 : min(len(udp), udp_len)]
    return (src, src_port, dst, dst_port), payload


@dataclass
class FlowState:
    remaining: int = 0
    active: bool = False


class AuthorizedMediaFilter:
    """Pass only verified GodSees media starts and continuation datagrams."""

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


def open_capture(interface: str) -> socket.socket:
    """Open non-promiscuous cooked capture on the dedicated WireGuard interface.

    Linux packet sockets take the protocol at socket creation. Binding with protocol
    zero then constrains only the interface while retaining the constructor protocol;
    this matches libpcap's cooked-capture pattern and avoids a second protocol-byte-
    order conversion in Python's AF_PACKET address tuple.
    """
    if not hasattr(socket, "AF_PACKET"):
        raise PublisherError("AF_PACKET unavailable on this platform")
    eth_p_all = int(getattr(socket, "ETH_P_ALL", ETH_P_ALL_FALLBACK))
    proto = socket.htons(eth_p_all)
    s = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, proto)
    try:
        s.bind((interface, 0))
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    except Exception:
        s.close()
        raise
    return s


def publish_once(interface: str, worker_socket: str, camera_id: str) -> None:
    write_status("starting", interface=interface, camera_id=camera_id)
    capture = open_capture(interface)
    write_status("capture_open", interface=interface, camera_id=camera_id, capture="af_packet_sock_dgram")
    worker: Optional[socket.socket] = None
    filt = AuthorizedMediaFilter()
    last_report = time.monotonic()
    try:
        worker = connect_worker(worker_socket, camera_id)
        write_status("publisher_registered", interface=interface, camera_id=camera_id, capture="af_packet_sock_dgram")
        print(
            json.dumps(
                {
                    "event": "publisher_registered",
                    "camera_id": camera_id,
                    "interface": interface,
                    "capture": "af_packet_sock_dgram",
                },
                sort_keys=True,
            ),
            flush=True,
        )
        while True:
            ip = capture.recv(65535)
            parsed = ipv4_udp_payload(ip)
            if not parsed:
                continue
            flow, payload = parsed
            if flow[1] != 80 and flow[3] != 80:
                continue
            if not filt.accept(flow, payload):
                continue
            send_frame(worker, payload)
            now = time.monotonic()
            if now - last_report >= 30:
                status = {
                    "forwarded": filt.forwarded,
                    "ignored": filt.ignored,
                    "interface": interface,
                    "camera_id": camera_id,
                }
                write_status("publisher_stats", **status)
                print(json.dumps({"event": "publisher_stats", **status}, sort_keys=True), flush=True)
                last_report = now
    finally:
        if worker is not None:
            worker.close()
        capture.close()


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
    parsed = ipv4_udp_payload(bytes(ip) + udp)
    assert parsed is not None
    flow, payload = parsed
    assert flow[1] == 80
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
            detail = str(exc)[:400]
            write_status("publisher_restart", error=type(exc).__name__, detail=detail, interface=args.interface, camera_id=args.camera_id)
            print(
                json.dumps(
                    {
                        "event": "publisher_restart",
                        "error": type(exc).__name__,
                        "detail": detail,
                    },
                    sort_keys=True,
                ),
                file=sys.stderr,
                flush=True,
            )
            time.sleep(3)


if __name__ == "__main__":
    raise SystemExit(main())
