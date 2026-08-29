#!/usr/bin/env python3
from __future__ import annotations

"""Nitu Camera authorized 360 FastConnect/GodSees worker.

This service is a local security and media boundary. It never manufactures vendor
credentials or bypasses device authorization. It accepts an already-authorized
session provider (local publisher) or proxies to a configured official SDK bridge.

Unix protocol: uint32 big-endian length followed by JSON or binary payload.
"""

import argparse
import asyncio
import contextlib
import json
import os
import pathlib
import socket
import struct
import sys
from dataclasses import dataclass
from typing import Optional

VERSION = "1.0.0"
DEFAULT_SOCKET = "/run/nitu-camera/godsees.sock"
MAX_FRAME = 8 * 1024 * 1024
RECORD_MAGIC = b"\x20\x14\x11\x04"
MEDIA_MARKERS = {b"\x1d\x00", b"\x1d\x02"}
VIDEO_TYPES = {2, 3}
AUDIO_TYPE = 4


class WorkerError(RuntimeError):
    pass


async def read_frame(reader: asyncio.StreamReader) -> bytes:
    hdr = await reader.readexactly(4)
    n = struct.unpack("!I", hdr)[0]
    if n > MAX_FRAME:
        raise WorkerError(f"frame too large: {n}")
    return await reader.readexactly(n)


async def write_frame(writer: asyncio.StreamWriter, data: bytes) -> None:
    if len(data) > MAX_FRAME:
        raise WorkerError("output frame too large")
    writer.write(struct.pack("!I", len(data)) + data)
    await writer.drain()


async def write_json(writer: asyncio.StreamWriter, obj: dict) -> None:
    await write_frame(writer, json.dumps(obj, separators=(",", ":"), sort_keys=True).encode())


@dataclass
class DemuxStats:
    datagrams: int = 0
    video_records: int = 0
    audio_records: int = 0
    video_bytes: int = 0
    audio_bytes: int = 0
    ignored: int = 0


class FastConnectMediaDemux:
    """Reassemble the observed authorized FastConnect media envelope.

    This is media framing only. Relay discovery, vendor signalling and session
    authorization are intentionally outside this class.
    """

    def __init__(self) -> None:
        self.current_type: Optional[int] = None
        self.remaining: Optional[int] = None
        self.stats = DemuxStats()

    def feed(self, packet: bytes) -> list[bytes]:
        self.stats.datagrams += 1
        if len(packet) < 10 or packet[6:8] not in MEDIA_MARKERS:
            self.stats.ignored += 1
            return []

        if len(packet) >= 68 and packet[14:18] == RECORD_MAGIC:
            kind = int.from_bytes(packet[18:20], "big")
            declared = int.from_bytes(packet[20:24], "big")
            self.current_type = kind if kind in VIDEO_TYPES | {AUDIO_TYPE} else None
            self.remaining = max(0, declared - 44) if declared >= 44 else None
            data = packet[68:]
            if kind in VIDEO_TYPES:
                self.stats.video_records += 1
            elif kind == AUDIO_TYPE:
                self.stats.audio_records += 1
        elif self.current_type is not None and (self.remaining is None or self.remaining > 0):
            data = packet[10:]
        else:
            self.stats.ignored += 1
            return []

        if self.remaining is not None:
            data = data[: self.remaining]
            self.remaining -= len(data)

        if self.current_type in VIDEO_TYPES:
            self.stats.video_bytes += len(data)
            return [data] if data else []
        if self.current_type == AUDIO_TYPE:
            self.stats.audio_bytes += len(data)
            return []
        return []


def _peer_uid(writer: asyncio.StreamWriter) -> Optional[int]:
    sock = writer.get_extra_info("socket")
    if sock is None or not hasattr(socket, "SO_PEERCRED"):
        return None
    try:
        raw = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, _gid = struct.unpack("3i", raw)
        return uid
    except OSError:
        return None


class Publisher:
    def __init__(self, camera_id: str, fmt: str, peer_uid: Optional[int]) -> None:
        self.camera_id = camera_id
        self.format = fmt
        self.peer_uid = peer_uid
        self.subscribers: set[asyncio.Queue[bytes]] = set()
        self.demux = FastConnectMediaDemux()

    async def broadcast(self, data: bytes) -> None:
        dead: list[asyncio.Queue[bytes]] = []
        for q in tuple(self.subscribers):
            try:
                q.put_nowait(data)
            except asyncio.QueueFull:
                dead.append(q)
        for q in dead:
            self.subscribers.discard(q)


class WorkerServer:
    def __init__(self, sock_path: str, bridge_unix: str = "", bridge_tcp: str = "", bridge_token_file: str = "") -> None:
        self.sock_path = sock_path
        self.bridge_unix = bridge_unix
        self.bridge_tcp = bridge_tcp
        self.bridge_token_file = bridge_token_file
        self.publishers: dict[str, Publisher] = {}
        self.server: Optional[asyncio.base_events.Server] = None
        self.client_tasks: set[asyncio.Task] = set()

    def _accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        task = asyncio.create_task(self.handle_client(reader, writer))
        self.client_tasks.add(task)
        task.add_done_callback(self.client_tasks.discard)

    def capabilities(self) -> dict:
        return {
            "publisher_ingest": True,
            "fastconnect_media_demux": True,
            "official_bridge_unix": bool(self.bridge_unix),
            "official_bridge_tcp": bool(self.bridge_tcp),
            "direct_cloud_signalling": False,
        }

    async def start(self) -> None:
        path = pathlib.Path(self.sock_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.suppress(FileNotFoundError):
            path.unlink()
        self.server = await asyncio.start_unix_server(self._accept, path=self.sock_path)
        os.chmod(self.sock_path, 0o660)

    async def close(self) -> None:
        if self.server:
            self.server.close()
        for task in tuple(self.client_tasks):
            task.cancel()
        if self.client_tasks:
            await asyncio.gather(*tuple(self.client_tasks), return_exceptions=True)
        if self.server:
            await self.server.wait_closed()
        with contextlib.suppress(FileNotFoundError):
            pathlib.Path(self.sock_path).unlink()

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            raw = await read_frame(reader)
            try:
                req = json.loads(raw.decode())
            except Exception as exc:
                raise WorkerError("first frame must be JSON") from exc
            op = str(req.get("op") or "")
            if op == "health":
                await write_json(writer, {
                    "ok": True,
                    "service": "nitu-camera-godsees",
                    "version": VERSION,
                    "codec": "h264",
                    "socket": self.sock_path,
                    "capabilities": self.capabilities(),
                    "publishers": len(self.publishers),
                })
            elif op == "publish":
                await self.handle_publish(req, reader, writer)
            elif op == "live":
                await self.handle_live(req, writer)
            else:
                await write_json(writer, {"ok": False, "error": "UNSUPPORTED_OPERATION"})
        except asyncio.IncompleteReadError:
            pass
        except Exception as exc:
            with contextlib.suppress(Exception):
                await write_json(writer, {"ok": False, "error": type(exc).__name__})
        finally:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()

    async def handle_publish(self, req: dict, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        camera_id = str(req.get("camera_id") or "").strip()
        fmt = str(req.get("format") or "annexb").lower()
        if not camera_id:
            await write_json(writer, {"ok": False, "error": "CAMERA_ID_REQUIRED"})
            return
        if fmt not in {"annexb", "fastconnect-datagram"}:
            await write_json(writer, {"ok": False, "error": "UNSUPPORTED_PUBLISH_FORMAT"})
            return
        if camera_id in self.publishers:
            await write_json(writer, {"ok": False, "error": "PUBLISHER_ALREADY_CONNECTED"})
            return

        pub = Publisher(camera_id, fmt, _peer_uid(writer))
        self.publishers[camera_id] = pub
        await write_json(writer, {"ok": True, "camera_id": camera_id, "format": fmt})
        await pub.broadcast(json.dumps({"event": "live", "backend": "authorized-publisher"}, separators=(",", ":")).encode())
        try:
            while True:
                payload = await read_frame(reader)
                if not payload:
                    continue
                if fmt == "annexb":
                    await pub.broadcast(payload)
                else:
                    for chunk in pub.demux.feed(payload):
                        await pub.broadcast(chunk)
        except asyncio.IncompleteReadError:
            pass
        finally:
            if self.publishers.get(camera_id) is pub:
                del self.publishers[camera_id]

    def _has_session_material(self, req: dict) -> bool:
        return bool(
            req.get("business_token")
            or req.get("relay_sign")
            or req.get("stream_keys")
        )

    async def _connect_bridge(self) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        if self.bridge_unix:
            return await asyncio.open_unix_connection(self.bridge_unix)
        if self.bridge_tcp:
            host, sep, port = self.bridge_tcp.rpartition(":")
            if not sep or not host:
                raise WorkerError("invalid GODSEES_OFFICIAL_BRIDGE_TCP")
            if host not in {"127.0.0.1", "::1", "localhost"}:
                raise WorkerError("official bridge TCP must be loopback")
            return await asyncio.open_connection(host, int(port))
        raise WorkerError("official bridge unavailable")

    def _bridge_token(self) -> str:
        if not self.bridge_token_file:
            return ""
        try:
            return pathlib.Path(self.bridge_token_file).read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    async def handle_live(self, req: dict, writer: asyncio.StreamWriter) -> None:
        camera_id = str(req.get("camera_id") or "").strip()
        serial = str(req.get("serial_number") or "").strip()
        if not camera_id or not serial:
            await write_json(writer, {"ok": False, "error": "CAMERA_ID_AND_SERIAL_REQUIRED"})
            return

        pub = self.publishers.get(camera_id)
        if pub is not None:
            await self.stream_publisher(pub, writer)
            return

        if self.bridge_unix or self.bridge_tcp:
            await self.stream_bridge(req, writer)
            return

        if not self._has_session_material(req):
            await write_json(writer, {
                "ok": False,
                "error": "AUTHORIZED_SESSION_MATERIAL_MISSING",
                "required": ["business_token/stream_keys/relay_sign", "authorized session provider"],
            })
            return

        await write_json(writer, {
            "ok": False,
            "error": "AUTHORIZED_SESSION_PROVIDER_UNAVAILABLE",
            "detail": "Install/configure the official SDK bridge or attach an authorized local publisher.",
        })

    async def stream_publisher(self, pub: Publisher, writer: asyncio.StreamWriter) -> None:
        q: asyncio.Queue[bytes] = asyncio.Queue(maxsize=128)
        pub.subscribers.add(q)
        try:
            await write_json(writer, {
                "ok": True,
                "codec": "h264",
                "backend": "authorized-publisher",
                "format": pub.format,
            })
            await write_json(writer, {"event": "live", "backend": "authorized-publisher"})
            while True:
                payload = await q.get()
                await write_frame(writer, payload)
        finally:
            pub.subscribers.discard(q)

    async def stream_bridge(self, req: dict, writer: asyncio.StreamWriter) -> None:
        br, bw = await self._connect_bridge()
        try:
            forwarded = dict(req)
            token = self._bridge_token()
            if token:
                forwarded["_bridge_auth"] = token
            await write_json(bw, forwarded)
            ack_raw = await read_frame(br)
            try:
                ack = json.loads(ack_raw.decode())
            except Exception:
                await write_json(writer, {"ok": False, "error": "OFFICIAL_BRIDGE_INVALID_ACK"})
                return
            if not ack.get("ok"):
                await write_json(writer, {"ok": False, "error": str(ack.get("error") or "OFFICIAL_BRIDGE_REJECTED")})
                return
            codec = str(ack.get("codec") or "h264").lower()
            if codec != "h264":
                await write_json(writer, {"ok": False, "error": "OFFICIAL_BRIDGE_CODEC_UNSUPPORTED"})
                return
            await write_json(writer, {"ok": True, "codec": "h264", "backend": "official-sdk-bridge"})
            while True:
                payload = await read_frame(br)
                await write_frame(writer, payload)
        except (ConnectionError, OSError, asyncio.IncompleteReadError):
            with contextlib.suppress(Exception):
                await write_json(writer, {"event": "bridge_disconnected"})
        finally:
            bw.close()
            with contextlib.suppress(Exception):
                await bw.wait_closed()


async def health_client(sock_path: str) -> int:
    try:
        reader, writer = await asyncio.open_unix_connection(sock_path)
        await write_json(writer, {"op": "health"})
        raw = await read_frame(reader)
        data = json.loads(raw.decode())
        print(json.dumps(data, sort_keys=True))
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()
        return 0 if data.get("ok") else 2
    except Exception as exc:
        print(json.dumps({"ok": False, "error": type(exc).__name__}), file=sys.stderr)
        return 2


async def serve(args: argparse.Namespace) -> int:
    server = WorkerServer(
        args.socket,
        bridge_unix=os.getenv("GODSEES_OFFICIAL_BRIDGE_UNIX", "").strip(),
        bridge_tcp=os.getenv("GODSEES_OFFICIAL_BRIDGE_TCP", "").strip(),
        bridge_token_file=os.getenv("GODSEES_OFFICIAL_BRIDGE_TOKEN_FILE", "").strip(),
    )
    await server.start()
    assert server.server is not None
    try:
        async with server.server:
            await server.server.serve_forever()
    finally:
        await server.close()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--serve", action="store_true")
    mode.add_argument("--health", action="store_true")
    ap.add_argument("--socket", default=os.getenv("GODSEES_SOCKET", DEFAULT_SOCKET))
    args = ap.parse_args()
    if args.serve:
        try:
            return asyncio.run(serve(args))
        except KeyboardInterrupt:
            return 130
    return asyncio.run(health_client(args.socket))


if __name__ == "__main__":
    raise SystemExit(main())
