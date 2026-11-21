"""Read-only access to the user's own WeChat 4.x databases (Windows; macOS works too for testing).

Uses the database key that WeFlow already captured (stored in WeFlow's config and protected by
Electron safeStorage). Databases are decrypted in memory only; nothing is written to disk and
nothing is ever written back to WeChat. Port of mac/Sources/WeChatDB.swift.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import sqlite3
import struct
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

from cryptography.hazmat.primitives import hashes, padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PAGE_SIZE = 4096
RESERVE = 80  # 16-byte IV + 64-byte HMAC-SHA512 at the end of every page
SQLITE_HEADER = b"SQLite format 3\x00"


class WeChatDBError(Exception):
    pass


@dataclass
class Account:
    storage: Path  # .../xwechat_files/<wxid_xxx>/db_storage
    my_wxid: str  # normalized, e.g. wxid_abc (without the 4-char folder suffix)
    raw_key: bytes
    derive: bool  # False: raw_key is the page key; True: PBKDF2(raw_key, salt) per database


@dataclass
class Session:
    username: str
    display_name: str
    last_timestamp: int
    unread_count: int


@dataclass
class Message:
    local_id: int
    create_time: int
    sort_seq: int
    is_send: bool
    type: int
    content: str
    sender: str


# ---------------------------------------------------------------- WeFlow config & key


def _weflow_dirs() -> list[Path]:
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return [base / "weflow", base / "WeFlow"]


def _weflow_dir() -> Path:
    for d in _weflow_dirs():
        if (d / "WeFlow-config.json").exists():
            return d
    raise WeChatDBError("没找到 WeFlow 的配置（需要先用 WeFlow 取到微信数据库密钥）。")


def _dpapi_unprotect(blob: bytes) -> bytes:
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    buf = ctypes.create_string_buffer(blob, len(blob))
    inp = DATA_BLOB(len(blob), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    out = DATA_BLOB()
    if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(inp), None, None, None, None, 0, ctypes.byref(out)):
        raise WeChatDBError("Windows DPAPI 解不开 WeFlow 的密钥（需要用同一个 Windows 账号运行）。")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out.pbData)


def _unprotect(s: str, weflow_dir: Path) -> str:
    """Undo Electron safeStorage ("safe:" + base64 of "v10"/"v11" + ciphertext)."""
    if not s.startswith("safe:"):
        return s
    try:
        blob = base64.b64decode(s[5:])
    except ValueError as e:
        raise WeChatDBError("WeFlow 密钥的加密格式不认识。") from e
    if blob[:3] not in (b"v10", b"v11"):
        raise WeChatDBError("WeFlow 密钥的加密格式不认识。")
    body = blob[3:]

    if sys.platform == "win32":
        # Chromium os_crypt on Windows: AES-256-GCM, key = DPAPI("Local State" → os_crypt.encrypted_key).
        try:
            state = json.loads((weflow_dir / "Local State").read_text(encoding="utf-8"))
            enc_key = base64.b64decode(state["os_crypt"]["encrypted_key"])
        except (OSError, KeyError, ValueError) as e:
            raise WeChatDBError("读不到 WeFlow 的 Local State（解密钥匙）。") from e
        if enc_key.startswith(b"DPAPI"):
            enc_key = enc_key[5:]
        key = _dpapi_unprotect(enc_key)
        try:
            plain = AESGCM(key).decrypt(body[:12], body[12:], None)
        except Exception as e:  # InvalidTag
            raise WeChatDBError("WeFlow 密钥解密失败。") from e
        return plain.decode("utf-8")

    if sys.platform == "darwin":
        password = None
        for service in ("weflow Safe Storage", "WeFlow Safe Storage"):
            r = subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                               capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip():
                password = r.stdout.strip().encode()
                break
        if password is None:
            raise WeChatDBError("钥匙串里没有 WeFlow 的密钥项（weflow Safe Storage）。")
        key = hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, 16)
        return _aes_cbc(body, key, b" " * 16, unpad=True).decode("utf-8")

    raise WeChatDBError("当前系统不支持解开 WeFlow 的密钥。")


def normalize_wxid(s: str) -> str:
    if s.lower().startswith("wxid_"):
        m = re.match(r"^wxid_[^_]+", s)
        if m:
            return m.group(0)
    m = re.search(r"_[a-zA-Z0-9]{4}$", s)
    return s[: m.start()] if m else s


# ---------------------------------------------------------------- crypto helpers


def _aes_cbc(data: bytes, key: bytes, iv: bytes, unpad: bool = False) -> bytes:
    d = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    out = d.update(data) + d.finalize()
    if unpad:
        u = padding.PKCS7(128).unpadder()
        out = u.update(out) + u.finalize()
    return out


def _pbkdf2_sha512(pw: bytes, salt: bytes, rounds: int, length: int = 32) -> bytes:
    return hashlib.pbkdf2_hmac("sha512", pw, salt, rounds, length)


def _mac_key(enc_key: bytes, salt: bytes) -> bytes:
    return _pbkdf2_sha512(enc_key, bytes(b ^ 0x3A for b in salt), 2)


def _verify_page(page: bytes, pgno: int, mac_key: bytes) -> bool:
    """SQLCipher 4 page check: HMAC-SHA512 over (ciphertext + IV + page number LE)."""
    if len(page) < PAGE_SIZE:
        return False
    start = 16 if pgno == 1 else 0
    msg = page[start : PAGE_SIZE - 64] + struct.pack("<I", pgno)
    mac = hmac.new(mac_key, msg, hashlib.sha512).digest()
    return hmac.compare_digest(mac, page[PAGE_SIZE - 64 : PAGE_SIZE])


def _decrypt_page(page: bytes, pgno: int, enc_key: bytes) -> bytes:
    start = 16 if pgno == 1 else 0
    iv = page[PAGE_SIZE - RESERVE : PAGE_SIZE - RESERVE + 16]
    body = _aes_cbc(page[start : PAGE_SIZE - RESERVE], enc_key, iv)
    return (SQLITE_HEADER if pgno == 1 else b"") + body + b"\x00" * RESERVE


# ---------------------------------------------------------------- the reader


class WeChatDB:
    SYSTEM_USERNAMES = {
        "filehelper", "weixin", "fmessage", "medianote", "floatbottle", "qqmail", "notifymessage",
        "newsapp", "brandsessionholder", "brandservicesessionholder", "opencustomerservicemsg", "qqsafe",
        "tmessage", "officialaccounts", "notification_messages", "mphelper", "@placeholder_foldgroup",
    }

    def __init__(self) -> None:
        self._account: Account | None = None
        self._cache: dict[str, tuple[str, sqlite3.Connection]] = {}
        self._key_cache: dict[str, tuple[bytes, bytes, bytes]] = {}
        self.lock = threading.RLock()  # all database work is serialized

    # -- key

    def account(self) -> Account:
        if self._account:
            return self._account
        wdir = _weflow_dir()
        try:
            cfg = json.loads((wdir / "WeFlow-config.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            raise WeChatDBError("WeFlow 配置读取失败。") from e
        db_path, folder = cfg.get("dbPath"), cfg.get("myWxid")
        if not db_path or not folder:
            raise WeChatDBError("WeFlow 配置里没有微信数据目录。")
        storage = Path(db_path) / folder / "db_storage"
        if not (storage / "session" / "session.db").exists():
            raise WeChatDBError(f"找不到微信数据库：{storage}")

        stored = cfg.get("decryptKey") or ""
        mine = (cfg.get("wxidConfigs") or {}).get(folder) or {}
        if mine.get("decryptKey"):
            stored = mine["decryptKey"]
        hexkey = _unprotect(stored, wdir).strip()
        try:
            raw = bytes.fromhex(hexkey)
        except ValueError:
            raw = b""
        if len(raw) != 32:
            raise WeChatDBError("WeFlow 里存的密钥格式不对。")

        with open(storage / "session" / "session.db", "rb") as f:
            page1 = f.read(PAGE_SIZE)
        salt = page1[:16]
        if _verify_page(page1, 1, _mac_key(raw, salt)):
            derive = False
        elif _verify_page(page1, 1, _mac_key(_pbkdf2_sha512(raw, salt, 256_000), salt)):
            derive = True
        else:
            raise WeChatDBError("密钥对不上当前的微信数据库（可能重新登录过微信），需要用 WeFlow 重新取一次密钥。")
        self._account = Account(storage, normalize_wxid(folder), raw, derive)
        return self._account

    # -- decrypt to an in-memory SQLite connection

    @staticmethod
    def _stamp(p: Path) -> str:
        parts = []
        for q in (p, Path(str(p) + "-wal")):
            try:
                st = q.stat()
                parts.append(f"{st.st_size}@{st.st_mtime_ns}")
            except OSError:
                parts.append("-1@0")
        return "|".join(parts)

    def open(self, rel: str) -> sqlite3.Connection:
        with self.lock:
            acct = self.account()
            path = acct.storage / rel
            stamp = self._stamp(path)
            hit = self._cache.get(rel)
            if hit and hit[0] == stamp:
                return hit[1]

            enc = path.read_bytes()
            if len(enc) < PAGE_SIZE:
                raise WeChatDBError(f"{rel} 太小")
            salt = enc[:16]
            k = self._key_cache.get(rel)
            if k and k[0] == salt:
                enc_key, mk = k[1], k[2]
            else:
                enc_key = _pbkdf2_sha512(acct.raw_key, salt, 256_000) if acct.derive else acct.raw_key
                mk = _mac_key(enc_key, salt)
                self._key_cache[rel] = (salt, enc_key, mk)

            zero = b"\x00" * PAGE_SIZE
            plain = bytearray()
            for i in range(len(enc) // PAGE_SIZE):
                page = enc[i * PAGE_SIZE : (i + 1) * PAGE_SIZE]
                plain += page if page == zero else _decrypt_page(page, i + 1, enc_key)

            # Apply committed WAL frames (newest messages usually live here until WeChat checkpoints).
            try:
                wal = Path(str(path) + "-wal").read_bytes()
            except OSError:
                wal = b""
            if len(wal) > 32:
                s1, s2 = struct.unpack(">II", wal[16:24])
                frame = 24 + PAGE_SIZE
                frames, last_commit, off = [], -1, 32
                while off + frame <= len(wal):
                    pgno, commit, f1, f2 = struct.unpack(">IIII", wal[off : off + 16])
                    if f1 != s1 or f2 != s2 or pgno == 0:
                        break
                    data = wal[off + 24 : off + frame]
                    if not _verify_page(data, pgno, mk):
                        break
                    frames.append((pgno, commit, data))
                    if commit:
                        last_commit = len(frames) - 1
                    off += frame
                if last_commit >= 0:
                    for pgno, _, data in frames[: last_commit + 1]:
                        o = (pgno - 1) * PAGE_SIZE
                        if o + PAGE_SIZE > len(plain):
                            plain += b"\x00" * (o + PAGE_SIZE - len(plain))
                        plain[o : o + PAGE_SIZE] = _decrypt_page(data, pgno, enc_key)
                    size = frames[last_commit][1] * PAGE_SIZE
                    if 0 < size < len(plain):
                        del plain[size:]

            # Header bytes 18/19 = 2 means WAL mode; an in-memory copy must be a rollback-journal database.
            plain[18] = 1
            plain[19] = 1
            conn = sqlite3.connect(":memory:", check_same_thread=False)
            conn.row_factory = sqlite3.Row
            try:
                conn.deserialize(bytes(plain))
            except sqlite3.DatabaseError as e:
                raise WeChatDBError(f"解密后的 {rel} 打不开：{e}") from e
            old = self._cache.get(rel)
            if old:
                old[1].close()
            self._cache[rel] = (stamp, conn)
            return conn

    def message_dbs(self) -> list[str]:
        d = self.account().storage / "message"
        names = [n for n in os.listdir(d) if re.fullmatch(r"message_\d+\.db", n)] if d.exists() else []
        names.sort(key=lambda n: int(re.sub(r"\D", "", n)), reverse=True)
        return [f"message/{n}" for n in names]

    # -- sessions & messages

    @classmethod
    def is_private_chat(cls, u: str) -> bool:
        l = u.lower()
        return bool(l) and "@" not in l and not l.startswith("gh_") and l not in cls.SYSTEM_USERNAMES

    def display_names(self, users: list[str]) -> dict[str, str]:
        out: dict[str, str] = {}
        if not users:
            return out
        with self.lock:
            c = self.open("contact/contact.db")
            for i in range(0, len(users), 400):
                chunk = users[i : i + 400]
                marks = ",".join("?" * len(chunk))
                for r in c.execute(f"SELECT username, remark, nick_name FROM contact WHERE username IN ({marks})", chunk):
                    out[r["username"]] = r["remark"] or r["nick_name"] or r["username"]
        return out

    def sessions(self, limit: int = 300) -> list[Session]:
        with self.lock:
            c = self.open("session/session.db")
            rows = c.execute(
                "SELECT username, unread_count, last_timestamp, sort_timestamp FROM SessionTable "
                "WHERE is_hidden = 0 ORDER BY sort_timestamp DESC LIMIT ?", (limit * 2,)
            ).fetchall()
            users = [r["username"] for r in rows if r["username"] and self.is_private_chat(r["username"])]
            names = self.display_names(users)
            return [Session(u, names.get(u, u), r["last_timestamp"] or 0, r["unread_count"] or 0)
                    for r in rows if (u := r["username"]) and self.is_private_chat(u)][:limit]

    def messages(self, talker: str, limit: int) -> list[Message]:
        """The latest `limit` messages with `talker`, oldest → newest (may span several message_N.db)."""
        with self.lock:
            acct = self.account()
            table = "Msg_" + hashlib.md5(talker.encode()).hexdigest()
            out: list[Message] = []
            for rel in self.message_dbs():
                c = self.open(rel)
                if not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                    continue
                senders = {r["id"]: r["user_name"] for r in c.execute("SELECT rowid AS id, user_name FROM Name2Id")}
                rows = c.execute(
                    f'SELECT local_id, local_type, sort_seq, real_sender_id, create_time, status, message_content '
                    f'FROM "{table}" ORDER BY sort_seq DESC LIMIT ?', (limit,)
                ).fetchall()
                for r in rows:
                    sender = senders.get(r["real_sender_id"] if r["real_sender_id"] is not None else -1, "") or ""
                    if sender:
                        is_send = normalize_wxid(sender) == acct.my_wxid or sender == acct.my_wxid
                    else:
                        is_send = r["status"] == 2
                    out.append(Message(r["local_id"] or 0, r["create_time"] or 0, r["sort_seq"] or 0, is_send,
                                       (r["local_type"] or 0) & 0xFFFFFFFF, _text(r["message_content"]), sender))
            out.sort(key=lambda m: (m.sort_seq, m.create_time))
            return out[-limit:]


_zstd = None


def _text(value) -> str:
    """message_content is TEXT, or a BLOB that may be zstd-compressed (WCDB compression)."""
    global _zstd
    if isinstance(value, str):
        return value
    if not value:
        return ""
    data = bytes(value)
    if data[:4] == b"\x28\xb5\x2f\xfd":
        try:
            if _zstd is None:
                import zstandard

                _zstd = zstandard.ZstdDecompressor()
            data = _zstd.decompressobj().decompress(data)
        except Exception:
            return ""
    return data.decode("utf-8", errors="replace")
