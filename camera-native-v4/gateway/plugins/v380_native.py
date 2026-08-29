from __future__ import annotations

"""Native V380 TCP/8800 live video plugin.

This implementation is an independent Python implementation derived from protocol
behaviour validated against the project's reference PCAP. It does not use the V380
APK at runtime and never logs camera credentials or session secrets.
"""

import asyncio
import hashlib
import secrets as pysecrets
import string
import struct
import time
from dataclasses import dataclass

import aiohttp
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from gateway.plugins.base import NativeCameraPlugin, PluginContext
from gateway.media.sink import looks_like_annexb
from protocols.v380 import lan_discover


class V380ProtocolError(RuntimeError):
    pass


@dataclass
class AuthState:
    ticket: int
    session: int
    device_version: int


def _u16le(b: bytes, off: int) -> int:
    return struct.unpack_from('<H', b, off)[0]


def _u32le(b: bytes, off: int) -> int:
    return struct.unpack_from('<I', b, off)[0]


def _put_u16le(b: bytearray, off: int, v: int) -> None:
    struct.pack_into('<H', b, off, v & 0xFFFF)


def _put_u32le(b: bytearray, off: int, v: int) -> None:
    struct.pack_into('<I', b, off, v & 0xFFFFFFFF)


def _aes_ecb_encrypt_blocks(data: bytes, key: bytes) -> bytes:
    if len(data) % 16:
        raise ValueError('AES ECB input must be block aligned')
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return enc.update(data) + enc.finalize()


def _aes_ecb_decrypt_blocks(data: bytes, key: bytes) -> bytes:
    if len(data) % 16:
        raise ValueError('AES ECB input must be block aligned')
    dec = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
    return dec.update(data) + dec.finalize()


def encode_v380_password(password: str, random_key: bytes | None = None) -> bytes:
    fixed = b'macrovideo+*#!^@'
    if random_key is None:
        alphabet = (string.ascii_letters + string.digits).encode()
        random_key = bytes(alphabet[pysecrets.randbelow(len(alphabet))] for _ in range(16))
    if len(random_key) != 16:
        raise ValueError('random_key must be 16 bytes')
    raw = password.encode('utf-8')[:48]
    padded = raw + b'\x00' * (48 - len(raw))
    once = _aes_ecb_encrypt_blocks(padded, fixed)
    twice = _aes_ecb_encrypt_blocks(once, random_key)
    return random_key + twice


def media_key_from_ticket(ticket: int) -> bytes:
    return struct.pack('<I', ticket & 0xFFFFFFFF) + struct.pack('<Q', 0x618123462C14795C) + struct.pack('<I', 0x82800DF0)


def decrypt_v380_video(payload: bytes, media_key: bytes) -> bytes:
    out = bytearray(payload)
    for off in range(0, len(out), 80):
        if off + 64 > len(out):
            break
        out[off:off + 64] = _aes_ecb_decrypt_blocks(bytes(out[off:off + 64]), media_key)
    return bytes(out)


def decrypt_v380_audio(payload: bytes, media_key: bytes) -> bytes:
    n = (len(payload) // 16) * 16
    if not n:
        return payload
    return _aes_ecb_decrypt_blocks(payload[:n], media_key) + payload[n:]


async def _read_exact(reader: asyncio.StreamReader, count: int, timeout: float = 8.0) -> bytes:
    return await asyncio.wait_for(reader.readexactly(count), timeout=timeout)


async def _open(host: str, port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    return await asyncio.wait_for(asyncio.open_connection(host, port), timeout=6.0)


async def _dispatch_relay(device_id: int, platform: int = 10001) -> str:
    ts = int(time.time())
    canonical = f'dev_id={device_id}&platform={platform}&timestamp={ts}hsdata2022'
    sign = hashlib.sha1(canonical.encode()).hexdigest()
    body = {'dev_id': int(device_id), 'platform': int(platform), 'timestamp': ts, 'sign': sign}
    endpoints = (
        'http://dispa1.av380.net:8001/api/v1/get_stream_server',
        'http://dispatch.av380.net:8001/api/v1/get_stream_server',
    )
    timeout = aiohttp.ClientTimeout(total=8)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        for url in endpoints:
            try:
                async with session.post(url, json=body) as resp:
                    if resp.status != 200:
                        continue
                    obj = await resp.json(content_type=None)
            except Exception:
                continue
            if int(obj.get('code', 0)) != 2000:
                continue
            for item in obj.get('data') or []:
                host = item.get('ip')
                if not host:
                    continue
                try:
                    _, w = await _open(str(host), 8800)
                    w.close(); await w.wait_closed()
                    return str(host)
                except Exception:
                    continue
    raise V380ProtocolError('no reachable V380 relay returned by dispatch')


async def _discover_host(device_id: str) -> str | None:
    try:
        replies = await lan_discover(timeout=1.5)
    except Exception:
        return None
    for r in replies:
        text = r.get('text', '')
        parts = text.split('^')
        if len(parts) >= 13 and parts[0] == 'NVDEVRESULT' and parts[12] == str(device_id):
            return r.get('from') or (parts[3] if len(parts) > 3 else None)
    return None


async def _auth(host: str, port: int, device_id: int, username: str, password: str, source: str) -> AuthState:
    reader, writer = await _open(host, port)
    try:
        req = bytearray(520)
        _put_u32le(req, 0, 1167)
        req[8] = 31
        _put_u32le(req, 9, 1)
        _put_u32le(req, 13, device_id)
        user = username.encode('utf-8')[:32]
        pwd = encode_v380_password(password)
        if source == 'lan':
            _put_u32le(req, 4, 120)
            req[49:49 + len(user)] = user
            req[81:81 + len(pwd)] = pwd
        else:
            _put_u32le(req, 4, 1022)
            domain = f'{device_id}.nvdvr.net'.encode()[:50]
            req[17:17 + len(domain)] = domain
            _put_u32le(req, 67, port)
            req[71:71 + len(user)] = user
            req[103:103 + len(pwd)] = pwd
        writer.write(req); await writer.drain()
        resp = await _read_exact(reader, 256)
        if _u32le(resp, 0) != 1168:
            raise V380ProtocolError('unexpected V380 authentication response')
        result = _u32le(resp, 4)
        if result != 1001:
            known = {1011: 'invalid username', 1012: 'invalid password', 1018: 'invalid device id'}
            raise V380ProtocolError(known.get(result, f'authentication rejected ({result})'))
        version = resp[12]
        ticket = _u32le(resp, 13)
        session = _u32le(resp, 17)
        if not ticket:
            raise V380ProtocolError('V380 returned an empty auth ticket')
        return AuthState(ticket=ticket, session=session, device_version=version)
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def _stream_login(host: str, port: int, device_id: int, state: AuthState, source: str, quality: int, audio: bool, cloud_mode: int = 1022):
    reader, writer = await _open(host, port)
    try:
        req = bytearray(256)
        _put_u32le(req, 0, 301)
        if source == 'lan':
            _put_u32le(req, 4, device_id)
            _put_u32le(req, 8, 0)
            _put_u16le(req, 12, 20)
            _put_u32le(req, 14, state.ticket)
            _put_u32le(req, 22, 4097 if audio else 4096)
            _put_u32le(req, 26, quality)
        else:
            _put_u32le(req, 4, cloud_mode)
            domain = f'{device_id}.nvdvr.net'.encode()[:50]
            req[8:8 + len(domain)] = domain
            _put_u32le(req, 58, port)
            _put_u32le(req, 62, device_id)
            _put_u32le(req, 66, state.ticket)
            _put_u32le(req, 70, state.session)
            _put_u32le(req, 74, quality)
            req[78] = 20
            _put_u32le(req, 79, 4097 if audio else 4096)
        writer.write(req); await writer.drain()
        resp_len = 412 if source == 'lan' else 44
        resp = await _read_exact(reader, resp_len)
        if _u32le(resp, 0) != 401:
            raise V380ProtocolError('unexpected V380 stream-login response')
        result = struct.unpack_from('<i', resp, 4)[0]
        if result in (-11, -12):
            raise V380ProtocolError(f'V380 stream login rejected ({result})')
        start = bytearray(256)
        _put_u32le(start, 0, 303)
        _put_u16le(start, 4, 0x3001)
        writer.write(start); await writer.drain()
        return reader, writer
    except Exception:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        raise


async def _fragment(reader: asyncio.StreamReader) -> tuple[int, int, int, bytes]:
    while True:
        b = await _read_exact(reader, 1, 12.0)
        if b == b'\x7f':
            rest = await _read_exact(reader, 11, 4.0)
            h = b + rest
            typ = h[1]
            total = _u16le(h, 3)
            cur = _u16le(h, 5)
            ln = _u16le(h, 7)
            if total and cur < total and 0 < ln <= 20000:
                return typ, total, cur, await _read_exact(reader, ln, 5.0)


class V380NativePlugin(NativeCameraPlugin):
    vendor = 'v380'
    codec = 'h264'

    async def run(self, ctx: PluginContext) -> None:
        camera, sec = ctx.camera, ctx.secrets
        device_id_s = str(camera.get('device_id') or sec.get('device_id') or '').strip()
        if not device_id_s.isdigit():
            raise V380ProtocolError('V380 camera requires numeric device_id')
        device_id = int(device_id_s)
        username = str(sec.get('username') or camera.get('username') or 'admin')
        password = str(sec.get('password') or '')
        if not password:
            raise V380ProtocolError('V380 password missing from encrypted vault')
        source = str(camera.get('source') or sec.get('source') or 'auto').lower()
        quality = 0 if str(camera.get('stream', 'main')).lower() in ('sub', 'sd', '0') else 1
        audio = bool(camera.get('audio', False))
        self.codec = str(camera.get('codec') or 'h264').lower()
        failures = 0
        while not ctx.stop_event.is_set():
            writer = None
            try:
                host = str(camera.get('host') or sec.get('host') or '').strip()
                effective_source = source
                if source in ('auto', 'lan') and not host:
                    host = await _discover_host(device_id_s) or ''
                    if host:
                        effective_source = 'lan'
                if not host:
                    if source == 'lan':
                        raise V380ProtocolError('camera not found on LAN')
                    host = await _dispatch_relay(device_id, int(camera.get('platform', 10001)))
                    effective_source = 'cloud'
                ctx.status.set('authenticating', f'V380 {effective_source} transport')
                port = int(camera.get('port', 8800))
                state = await _auth(host, port, device_id, username, password, effective_source)
                ctx.status.set('connecting', f'V380 TCP/8800 protocol v{state.device_version}')
                if effective_source == 'cloud':
                    configured = int(camera.get('cloud_mode', 1022))
                    modes_to_try = [configured] + [m for m in (1022, 1002) if m != configured]
                    last_exc = None
                    for mode in modes_to_try:
                        try:
                            reader, writer = await _stream_login(host, port, device_id, state, effective_source, quality, audio, mode)
                            break
                        except V380ProtocolError as exc:
                            last_exc = exc
                    else:
                        raise last_exc or V380ProtocolError('cloud stream login failed')
                else:
                    reader, writer = await _stream_login(host, port, device_id, state, effective_source, quality, audio, 0)
                key = media_key_from_ticket(state.ticket)
                video_parts = []
                video_total = 0
                validated = False
                failures = 0
                while not ctx.stop_event.is_set():
                    typ, total, cur, data = await _fragment(reader)
                    ctx.status.packets += 1
                    ctx.status.bytes_in += len(data) + 12
                    if typ not in (0x00, 0x01):
                        continue
                    if cur == 0 or total != video_total:
                        video_parts = []
                        video_total = total
                    video_parts.append(data)
                    if cur != total - 1:
                        continue
                    full = b''.join(video_parts)
                    video_parts = []
                    if len(full) <= 16:
                        continue
                    payload = full[16:]
                    if state.device_version > 30:
                        payload = decrypt_v380_video(payload, key)
                    if not looks_like_annexb(payload[:64]):
                        continue
                    if not validated:
                        ctx.status.decoder_ready = True
                        ctx.status.set('live', f'V380 native H.264 decoder validated; TCP/8800 via {effective_source}')
                        validated = True
                    await ctx.sink.write(payload)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                failures += 1
                ctx.status.decoder_ready = False
                ctx.status.set('reconnecting', f'V380 decoder retry {failures}: {type(exc).__name__}: {exc}')
                try:
                    await asyncio.wait_for(ctx.stop_event.wait(), timeout=min(30, 2 * failures))
                except asyncio.TimeoutError:
                    pass
            finally:
                if writer is not None:
                    writer.close()
                    try:
                        await writer.wait_closed()
                    except Exception:
                        pass
