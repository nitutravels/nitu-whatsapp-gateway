#!/usr/bin/env python3
import asyncio
import array
import json
import logging
import math
import os
import re
import subprocess
import sys
import tempfile
import time
import uuid
import wave
from urllib.parse import parse_qs

from aiohttp import web, ClientSession, ClientTimeout
from faster_whisper import WhisperModel

HOST = os.getenv('VOICE_BIND', '127.0.0.1')
PORT = int(os.getenv('VOICE_PORT', '8790'))
WHISPER_MODEL = os.getenv('WHISPER_MODEL', 'base')
HF_HOME = os.getenv('HF_HOME', '/opt/nitu-control/voice-v1/cache')
RMS_THRESHOLD = int(os.getenv('RMS_THRESHOLD', '550'))
SILENCE_MS = int(os.getenv('SILENCE_MS', '850'))
MIN_SPEECH_MS = int(os.getenv('MIN_SPEECH_MS', '300'))
MAX_UTTERANCE_MS = int(os.getenv('MAX_UTTERANCE_MS', '20000'))
BACKEND_URL = os.getenv('NITU_AGENT_BACKEND_URL', '').strip()
BACKEND_TOKEN = os.getenv('NITU_AGENT_BACKEND_TOKEN', '').strip()
OLLAMA_URL = os.getenv('OLLAMA_URL', 'http://127.0.0.1:11434').rstrip('/')
OLLAMA_MODEL = os.getenv('OLLAMA_MODEL', 'qwen2.5:3b')
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO').upper()

logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO),
                    format='%(asctime)s %(levelname)s %(name)s %(message)s')
log = logging.getLogger('nitu-voice')
os.environ.setdefault('HF_HOME', HF_HOME)
model = WhisperModel(WHISPER_MODEL, device='cpu', compute_type='int8')
model_loaded_at = time.time()


def pcm16_rms(data: bytes) -> int:
    """RMS for little-endian signed 16-bit PCM without deprecated audioop."""
    if len(data) < 2:
        return 0
    usable = len(data) - (len(data) % 2)
    samples = array.array('h')
    samples.frombytes(data[:usable])
    if sys.byteorder != 'little':
        samples.byteswap()
    if not samples:
        return 0
    mean_square = sum(int(v) * int(v) for v in samples) / len(samples)
    return int(math.sqrt(mean_square))


def wav_from_pcm16(pcm: bytes, path: str) -> None:
    with wave.open(path, 'wb') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(16000)
        wf.writeframes(pcm)


def transcribe_sync(pcm: bytes) -> str:
    if not pcm:
        return ''
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
        path = f.name
    try:
        wav_from_pcm16(pcm, path)
        segments, _ = model.transcribe(
            path,
            beam_size=1,
            vad_filter=True,
            condition_on_previous_text=False,
        )
        return ' '.join(s.text.strip() for s in segments).strip()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def choose_espeak_voice(text: str) -> str:
    return 'hi' if re.search(r'[\u0900-\u097F]', text) else 'en-in'


def tts_sync(text: str) -> bytes:
    clean = ' '.join(text.strip().split())[:800]
    if not clean:
        return b''
    p1 = subprocess.Popen(
        ['espeak-ng', '-v', choose_espeak_voice(clean), '-s', '165', '--stdout', clean],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    p2 = subprocess.Popen(
        ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'wav', '-i', 'pipe:0',
         '-ac', '1', '-ar', '16000', '-f', 's16le', 'pipe:1'],
        stdin=p1.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert p1.stdout is not None
    p1.stdout.close()
    out, err2 = p2.communicate(timeout=40)
    _, err1 = p1.communicate(timeout=10)
    if p1.returncode != 0 or p2.returncode != 0:
        raise RuntimeError(
            f'TTS failed espeak={p1.returncode} ffmpeg={p2.returncode}: '
            f'{err1.decode(errors="ignore")} {err2.decode(errors="ignore")}'
        )
    return out


async def backend_reply(session: ClientSession, payload: dict):
    if not BACKEND_URL:
        return None
    headers = {'Content-Type': 'application/json'}
    if BACKEND_TOKEN:
        headers['Authorization'] = f'Bearer {BACKEND_TOKEN}'
    try:
        async with session.post(
            BACKEND_URL,
            json=payload,
            headers=headers,
            timeout=ClientTimeout(total=20),
        ) as resp:
            body = await resp.json(content_type=None)
            if resp.status >= 400:
                log.warning('Nitu backend HTTP %s: %s', resp.status, body)
                return None
            reply = body.get('reply') or body.get('text') or body.get('message')
            return str(reply).strip() if reply else None
    except Exception:
        log.exception('Nitu backend request failed')
        return None


async def ollama_reply(session: ClientSession, text: str, caller: str, direction: str):
    try:
        async with session.get(f'{OLLAMA_URL}/api/tags', timeout=ClientTimeout(total=1.5)) as resp:
            if resp.status != 200:
                return None
    except Exception:
        return None
    system = (
        'You are Nitu Travels internal voice assistant for staff and existing clients. '
        'Speak in concise natural Hindi/Hinglish. Never invent booking, duty, payment, driver, '
        'vehicle or GPS facts. If live Nitu data is unavailable, say you cannot verify it and '
        'offer to connect the caller to operations. Do not perform promotional sales outreach.'
    )
    body = {
        'model': OLLAMA_MODEL,
        'stream': False,
        'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': f'Caller: {caller or "unknown"}; direction: {direction}; message: {text}'},
        ],
        'options': {'temperature': 0.2},
    }
    try:
        async with session.post(f'{OLLAMA_URL}/api/chat', json=body,
                                timeout=ClientTimeout(total=45)) as resp:
            if resp.status != 200:
                return None
            data = await resp.json()
            return ((data.get('message') or {}).get('content') or '').strip() or None
    except Exception:
        log.exception('Ollama request failed')
        return None


def fallback_reply(text: str) -> str:
    t = text.lower()
    if any(x in t for x in ('hello', 'hi', 'namaste', 'नमस्ते')):
        return 'Namaste. Nitu Travels voice assistant bol raha hoon. Batayiye.'
    if any(x in t for x in ('duty', 'booking', 'driver', 'vehicle', 'bus', 'payment',
                             'invoice', 'location', 'gps', 'tracking')):
        return (
            'Voice calling path sahi chal raha hai, lekin live Nitu backend abhi connect nahi hai. '
            'Main bina verify kiye duty ya booking ki detail nahi bataunga.'
        )
    if any(x in t for x in ('bye', 'thank', 'thanks', 'dhanyavad', 'धन्यवाद')):
        return 'Dhanyavad. Nitu Travels.'
    return (
        'Aapki awaaz samajh aa rahi hai. Ye safe read only mode hai. '
        'Live staff aur client information ke liye Nitu backend connect hona zaroori hai.'
    )


async def make_reply(session, text, caller, direction, conversation_id):
    payload = {
        'channel': 'voice',
        'direction': direction,
        'caller_id': caller,
        'conversation_id': conversation_id,
        'text': text,
        'mode': 'read_only',
    }
    return (
        await backend_reply(session, payload)
        or await ollama_reply(session, text, caller, direction)
        or fallback_reply(text)
    )


async def send_pcm(ws, pcm: bytes):
    for i in range(0, len(pcm), 6400):
        await ws.send_bytes(pcm[i:i + 6400])
        await asyncio.sleep(0)


async def speak(ws, text: str):
    log.info('assistant: %s', text)
    pcm = await asyncio.to_thread(tts_sync, text)
    if pcm and not ws.closed:
        await send_pcm(ws, pcm)


async def media_handler(request):
    ws = web.WebSocketResponse(protocols=('media',), heartbeat=20, max_msg_size=4 * 1024 * 1024)
    await ws.prepare(request)
    qs = parse_qs(request.query_string)
    caller = (qs.get('caller') or [''])[0]
    called = (qs.get('called') or [''])[0]
    direction = (qs.get('direction') or ['inbound'])[0]
    conversation_id = str(uuid.uuid4())
    log.info('call connected id=%s direction=%s caller=%s called=%s',
             conversation_id, direction, caller, called)
    buf = bytearray()
    speaking = False
    speech_ms = 0.0
    silence_ms = 0.0
    processing = False
    greeted = False
    async with ClientSession() as session:
        async def process_utterance(pcm):
            nonlocal processing
            try:
                text = await asyncio.to_thread(transcribe_sync, pcm)
                if not text:
                    return
                log.info('caller[%s]: %s', caller or 'unknown', text)
                await speak(ws, await make_reply(session, text, caller, direction, conversation_id))
            except Exception:
                log.exception('utterance processing failed')
                try:
                    await speak(ws, 'Maaf kijiye, voice processing mein dikkat aayi hai.')
                except Exception:
                    pass
            finally:
                processing = False

        async for msg in ws:
            if msg.type == web.WSMsgType.TEXT:
                raw = msg.data
                try:
                    control = json.loads(raw)
                except Exception:
                    control = {'event': raw}
                event_name = str(control.get('event') or control.get('type') or raw)
                if 'MEDIA_START' in event_name.upper() and not greeted:
                    greeted = True
                    if direction != 'outbound':
                        await speak(ws, 'Namaste. Nitu Travels virtual assistant bol raha hoon. Batayiye main kya madad kar sakta hoon.')
                continue
            if msg.type == web.WSMsgType.BINARY:
                if processing:
                    continue
                data = bytes(msg.data)
                if not data:
                    continue
                frame_ms = len(data) / (2 * 16000) * 1000.0
                voiced = pcm16_rms(data) >= RMS_THRESHOLD
                if not speaking:
                    if voiced:
                        speaking = True
                        buf.clear()
                        buf.extend(data)
                        speech_ms = frame_ms
                        silence_ms = 0.0
                    continue
                buf.extend(data)
                if voiced:
                    speech_ms += frame_ms
                    silence_ms = 0.0
                else:
                    silence_ms += frame_ms
                total_ms = len(buf) / (2 * 16000) * 1000.0
                if ((silence_ms >= SILENCE_MS and speech_ms >= MIN_SPEECH_MS)
                        or total_ms >= MAX_UTTERANCE_MS):
                    pcm = bytes(buf)
                    buf.clear()
                    speaking = False
                    speech_ms = 0.0
                    silence_ms = 0.0
                    processing = True
                    asyncio.create_task(process_utterance(pcm))
                continue
            if msg.type in (web.WSMsgType.CLOSE, web.WSMsgType.CLOSED, web.WSMsgType.ERROR):
                break
    log.info('call disconnected id=%s', conversation_id)
    return ws


async def health_handler(_request):
    return web.json_response({
        'ok': True,
        'service': 'nitu-voice-agent',
        'whisper_model': WHISPER_MODEL,
        'model_loaded_seconds_ago': round(time.time() - model_loaded_at, 1),
        'backend_configured': bool(BACKEND_URL),
        'ollama_url': OLLAMA_URL,
        'python': sys.version.split()[0],
    })


app = web.Application(client_max_size=4 * 1024 * 1024)
app.router.add_get('/media', media_handler)
app.router.add_get('/health', health_handler)

if __name__ == '__main__':
    web.run_app(app, host=HOST, port=PORT, access_log=None)
