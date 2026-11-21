"""Windows-only checks run in CI (no WeChat needed): Electron safeStorage decoding and the window finder."""

import base64
import ctypes
import json
import os
import sys
import tempfile
from ctypes import wintypes
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import wechat_db  # noqa: E402


class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def dpapi_protect(data: bytes) -> bytes:
    buf = ctypes.create_string_buffer(data, len(data))
    inp = DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    out = DATA_BLOB()
    assert ctypes.windll.crypt32.CryptProtectData(ctypes.byref(inp), None, None, None, None, 0, ctypes.byref(out))
    return ctypes.string_at(out.pbData, out.cbData)


def test_safe_storage_roundtrip():
    master = os.urandom(32)
    secret = os.urandom(32).hex()
    nonce = os.urandom(12)
    blob = b"v10" + nonce + AESGCM(master).encrypt(nonce, secret.encode(), None)
    with tempfile.TemporaryDirectory() as d:
        Path(d, "Local State").write_text(json.dumps(
            {"os_crypt": {"encrypted_key": base64.b64encode(b"DPAPI" + dpapi_protect(master)).decode()}}))
        got = wechat_db._unprotect("safe:" + base64.b64encode(blob).decode(), Path(d))
    assert got == secret


def test_plain_key_passthrough():
    assert wechat_db._unprotect("abcd", Path(".")) == "abcd"


def test_window_finder_without_wechat():
    import coach

    assert coach.WeChatWindow.find() is None


def test_page_crypto_roundtrip():
    """Encrypt one SQLCipher-4 page the way WeChat does and check verify + decrypt."""
    import hashlib
    import hmac
    import struct

    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    key, salt, iv = os.urandom(32), os.urandom(16), os.urandom(16)
    plain = os.urandom(wechat_db.PAGE_SIZE - 16 - wechat_db.RESERVE)
    e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    body = salt + e.update(plain) + e.finalize() + iv
    mk = wechat_db._mac_key(key, salt)
    mac = hmac.new(mk, body[16:] + struct.pack("<I", 1), hashlib.sha512).digest()
    page = body + mac
    assert len(page) == wechat_db.PAGE_SIZE
    assert wechat_db._verify_page(page, 1, mk)
    out = wechat_db._decrypt_page(page, 1, key)
    assert out.startswith(wechat_db.SQLITE_HEADER) and out[16:16 + len(plain)] == plain


def test_find_storage_and_check_key(tmp_path):
    """A fake xwechat_files/<account>/db_storage whose session.db page 1 is encrypted with a known key."""
    import hashlib
    import hmac
    import struct

    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    key, salt, iv = os.urandom(32), os.urandom(16), os.urandom(16)
    e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    body = salt + e.update(os.urandom(wechat_db.PAGE_SIZE - 16 - wechat_db.RESERVE)) + e.finalize() + iv
    page = body + hmac.new(wechat_db._mac_key(key, salt), body[16:] + struct.pack("<I", 1), hashlib.sha512).digest()
    st = tmp_path / "xwechat_files" / "wxid_test_ab12" / "db_storage"
    (st / "session").mkdir(parents=True)
    (st / "session" / "session.db").write_bytes(page)

    found = wechat_db.find_storages([tmp_path / "xwechat_files"])
    assert st in found
    assert wechat_db.check_key(st, key) is False
    assert wechat_db.check_key(st, os.urandom(32)) is None
    db = wechat_db.WeChatDB(saved_key=lambda a: None, extra_roots=[tmp_path / "xwechat_files"])
    db._from_weflow = lambda: (_ for _ in ()).throw(wechat_db.WeChatDBError("no weflow"))
    try:
        db.account()
        raise AssertionError("expected NeedKey")
    except wechat_db.NeedKey:
        pass
    assert db.use_key(key.hex()).storage == st
