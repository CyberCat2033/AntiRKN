#!/usr/bin/env python3
"""Optional regeneration of a PUBLIC deterministic vector using libsodium."""
import base64
import ctypes
import ctypes.util
import json
from pathlib import Path
import struct

root = Path(__file__).resolve().parent.parent
lib = ctypes.CDLL(ctypes.util.find_library('sodium'))
lib.sodium_init()
lib.sodium_version_string.restype = ctypes.c_char_p
key = bytes(range(32))
nonce = bytes(range(24))
header = {
    'version': 1, 'workspaceId': 'a' * 32, 'deviceId': 'b' * 32,
    'changeId': 'c' * 32, 'sequence': 7, 'transactionId': 'd' * 32,
    'transactionIndex': 0, 'transactionSize': 1,
    'entityKind': 'server', 'entityId': 'fixture-server',
    'baseChangeId': None, 'baseRevision': 0, 'revision': 1, 'deleted': False,
}
body = {'header': header, 'source': '{"secret":"PUBLIC-test-vector-only"}'}
plain = json.dumps(body, sort_keys=True, separators=(',', ':')).encode()
aad = b'AntiRKNS' + bytes([1, 1]) + struct.pack('>I', 1) + bytes.fromhex(header['workspaceId'] + header['changeId'])
cipher = ctypes.create_string_buffer(len(plain) + 16)
length = ctypes.c_ulonglong()
fn = lib.crypto_aead_xchacha20poly1305_ietf_encrypt
fn.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulonglong),
               ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p,
               ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_void_p,
               ctypes.c_void_p]
if fn(cipher, ctypes.byref(length), plain, len(plain), aad, len(aad), None, nonce, key):
    raise SystemExit('libsodium encryption failed')
fixture = {
    'generator': 'libsodium ' + lib.sodium_version_string().decode(),
    'key': key.hex(), 'nonce': nonce.hex(), 'body': body,
    'packet': base64.b64encode(aad + nonce + cipher.raw[:length.value]).decode(),
}
target = root / 'packages/sync/test/fixtures/libsodium-packet.json'
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(fixture, indent=2) + '\n')
print('Public libsodium vector generated')
