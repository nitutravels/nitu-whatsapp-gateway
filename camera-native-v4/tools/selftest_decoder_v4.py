#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, os, pathlib, struct, sys, types
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
ROOT=pathlib.Path(__file__).resolve().parents[1]

gateway=types.ModuleType('gateway'); gateway.__path__=[]
plugins=types.ModuleType('gateway.plugins'); plugins.__path__=[]
base=types.ModuleType('gateway.plugins.base')
class NativeCameraPlugin: pass
class PluginContext: pass
base.NativeCameraPlugin=NativeCameraPlugin; base.PluginContext=PluginContext
media=types.ModuleType('gateway.media'); media.__path__=[]
sink=types.ModuleType('gateway.media.sink')
sink.looks_like_annexb=lambda b: b'\x00\x00\x00\x01' in b or b'\x00\x00\x01' in b
protocols=types.ModuleType('protocols'); protocols.__path__=[]
v380proto=types.ModuleType('protocols.v380')
async def lan_discover(*args, **kwargs): return []
v380proto.lan_discover=lan_discover
for n,m in [('gateway',gateway),('gateway.plugins',plugins),('gateway.plugins.base',base),('gateway.media',media),('gateway.media.sink',sink),('protocols',protocols),('protocols.v380',v380proto)]:
    sys.modules[n]=m
spec=importlib.util.spec_from_file_location('camera_v4_v380', ROOT/'gateway/plugins/v380_native.py')
mod=importlib.util.module_from_spec(spec); sys.modules[spec.name]=mod; spec.loader.exec_module(mod)

def enc_selective(clear,key):
    b=bytearray(clear)
    for off in range(0,len(b),80):
        if off+64>len(b): break
        enc=Cipher(algorithms.AES(key),modes.ECB()).encryptor()
        b[off:off+64]=enc.update(bytes(b[off:off+64]))+enc.finalize()
    return bytes(b)

k=mod.media_key_from_ticket(0x12345678)
assert len(k)==16 and k[:4]==struct.pack('<I',0x12345678)
clear=b'\x00\x00\x00\x01'+os.urandom(236)
assert mod.decrypt_v380_video(enc_selective(clear,k),k)==clear
field=mod.encode_v380_password('example',b'0123456789ABCDEF')
assert len(field)==64 and field[:16]==b'0123456789ABCDEF'
print('decoder-v4 self-test: PASS')
