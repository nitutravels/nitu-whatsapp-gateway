from __future__ import annotations

"""360 FastConnect/GodSees decoder worker boundary.

The network capture validates BX_relay/live_camera_v2 transport. 360's published IoT
SDK exposes the GodSees session, stream-key update, and media decryption functions in
QHVCNetGodSees/liblocalserver. The vendor SDK is not redistributed here. A local
root-owned worker can expose decoded Annex-B frames over this private Unix socket.
"""

import asyncio
import json
import os
import pathlib
import struct

from gateway.plugins.base import NativeCameraPlugin, PluginContext
from gateway.media.sink import looks_like_annexb


class GodSeesWorkerError(RuntimeError):
    pass


async def _read_msg(reader: asyncio.StreamReader) -> bytes:
    hdr = await reader.readexactly(4)
    n = struct.unpack('!I', hdr)[0]
    if n > 8 * 1024 * 1024:
        raise GodSeesWorkerError('worker frame too large')
    return await reader.readexactly(n)


async def _send_json(writer: asyncio.StreamWriter, obj: dict) -> None:
    data = json.dumps(obj, separators=(',', ':')).encode()
    writer.write(struct.pack('!I', len(data)) + data)
    await writer.drain()


class Camera360GodSeesPlugin(NativeCameraPlugin):
    vendor = 'camera360'
    codec = 'h264'

    async def run(self, ctx: PluginContext) -> None:
        camera, sec = ctx.camera, ctx.secrets
        sock = str(camera.get('godsees_socket') or os.getenv('GODSEES_SOCKET', '/run/nitu-camera/godsees.sock'))
        if not pathlib.Path(sock).exists():
            raise GodSeesWorkerError(
                '360 GodSees SDK worker is not installed; QHVCNetGodSees/liblocalserver is required for authorized media decryption'
            )
        serial = str(camera.get('device_id') or sec.get('serial_number') or '')
        if not serial:
            raise GodSeesWorkerError('360 serial/device id missing')
        reader, writer = await asyncio.open_unix_connection(sock)
        try:
            await _send_json(writer, {
                'op': 'live',
                'camera_id': camera['id'],
                'serial_number': serial,
                'product_id': sec.get('product_id') or camera.get('product_id'),
                'business_token': sec.get('business_token') or '',
                'stream_keys': sec.get('stream_keys') or {},
                'relay_sign': sec.get('relay_sign'),
                'transport': {'service': 'live_camera_v2', 'route': 'BX_relay'},
                'stream': 'sub' if str(camera.get('stream', 'main')).lower() in ('sub', 'sd', '0') else 'main',
            })
            ack = json.loads((await _read_msg(reader)).decode())
            if not ack.get('ok'):
                raise GodSeesWorkerError(str(ack.get('error') or 'GodSees worker rejected session'))
            codec = str(ack.get('codec') or 'h264').lower()
            if codec != self.codec:
                raise GodSeesWorkerError(f'worker codec {codec} does not match configured HLS sink codec {self.codec}')
            ctx.status.decoder_ready = True
            ctx.status.set('connecting', '360 GodSees SDK session established')
            while not ctx.stop_event.is_set():
                data = await _read_msg(reader)
                if not data:
                    continue
                if data[:1] == b'{':
                    try:
                        event = json.loads(data.decode())
                        if event.get('event') == 'live':
                            ctx.status.set('live', '360 FastConnect/GodSees decoded stream')
                    except Exception:
                        pass
                    continue
                ctx.status.packets += 1
                ctx.status.bytes_in += len(data)
                if looks_like_annexb(data[:64]):
                    ctx.status.set('live', '360 FastConnect/GodSees decoded stream')
                    await ctx.sink.write(data)
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
