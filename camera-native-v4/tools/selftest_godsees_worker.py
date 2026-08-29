#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import contextlib
import importlib.util
import json
import pathlib
import struct
import sys
import tempfile

WORKER = pathlib.Path(__file__).resolve().parents[1] / "worker" / "godsees_worker.py"
spec = importlib.util.spec_from_file_location("godsees_worker", WORKER)
mod = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)


def frame(data: bytes) -> bytes:
    return struct.pack("!I", len(data)) + data


async def read_frame(reader: asyncio.StreamReader) -> bytes:
    n = struct.unpack("!I", await reader.readexactly(4))[0]
    return await reader.readexactly(n)


async def send_json(writer: asyncio.StreamWriter, obj: dict) -> None:
    data = json.dumps(obj, separators=(",", ":")).encode()
    writer.write(frame(data))
    await writer.drain()


def make_start(seq: int, kind: int, whole_len: int, data: bytes) -> bytes:
    h = bytearray(68)
    h[2:4] = seq.to_bytes(2, "big")
    h[6:8] = b"\x1d\x00"
    h[14:18] = mod.RECORD_MAGIC
    h[18:20] = kind.to_bytes(2, "big")
    h[20:24] = (44 + whole_len).to_bytes(4, "big")
    return bytes(h) + data


def make_cont(seq: int, data: bytes) -> bytes:
    h = bytearray(10)
    h[2:4] = seq.to_bytes(2, "big")
    h[6:8] = b"\x1d\x00"
    return bytes(h) + data


def test_demux() -> None:
    d = mod.FastConnectMediaDemux()
    video = b"\x00\x00\x00\x01\x67" + b"V" * 77
    audio = b"\xff\xf1" + b"A" * 31
    out = []
    out += d.feed(make_start(1, 2, len(video), video[:25]))
    out += d.feed(make_cont(2, video[25:]))
    out += d.feed(make_start(3, 4, len(audio), audio))
    assert b"".join(out) == video
    assert d.stats.video_records == 1
    assert d.stats.audio_records == 1
    assert d.stats.video_bytes == len(video)
    assert d.stats.audio_bytes == len(audio)


async def integration() -> None:
    with tempfile.TemporaryDirectory() as td:
        sock = str(pathlib.Path(td) / "godsees.sock")
        server = mod.WorkerServer(sock)
        await server.start()
        assert server.server is not None
        try:
            r, w = await asyncio.open_unix_connection(sock)
            await send_json(w, {"op": "health"})
            health = json.loads((await read_frame(r)).decode())
            assert health["ok"] is True
            assert health["capabilities"]["direct_cloud_signalling"] is False
            w.close()
            await w.wait_closed()

            r, w = await asyncio.open_unix_connection(sock)
            await send_json(w, {
                "op": "live", "camera_id": "cam360", "serial_number": "serial",
                "business_token": "", "stream_keys": {}, "relay_sign": None,
            })
            denied = json.loads((await read_frame(r)).decode())
            assert denied["ok"] is False
            assert denied["error"] == "AUTHORIZED_SESSION_MATERIAL_MISSING"
            w.close()
            await w.wait_closed()

            pr, pw = await asyncio.open_unix_connection(sock)
            await send_json(pw, {"op": "publish", "camera_id": "cam360", "format": "fastconnect-datagram"})
            pack = json.loads((await read_frame(pr)).decode())
            assert pack["ok"] is True

            lr, lw = await asyncio.open_unix_connection(sock)
            await send_json(lw, {"op": "live", "camera_id": "cam360", "serial_number": "serial"})
            lack = json.loads((await read_frame(lr)).decode())
            assert lack["ok"] is True and lack["codec"] == "h264"
            event = json.loads((await read_frame(lr)).decode())
            assert event["event"] == "live"

            video = b"\x00\x00\x00\x01\x65" + b"K" * 60
            packet = make_start(10, 2, len(video), video)
            pw.write(frame(packet))
            await pw.drain()
            got = await asyncio.wait_for(read_frame(lr), timeout=2)
            assert got == video

            lw.close()
            pw.close()
            await lw.wait_closed()
            await pw.wait_closed()
        finally:
            await server.close()


def main() -> int:
    test_demux()
    asyncio.run(integration())
    print("godsees-worker self-test: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
