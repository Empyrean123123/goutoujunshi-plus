"""狗头军师 · 微信恋爱教练 — Windows floating panel (port of mac/Sources/main.swift).

Reads your own WeChat 4.x chat history locally (via the key WeFlow captured), sends the recent
transcript to Claude, and shows ready-to-send replies as copy buttons.

    python coach.py                  # the panel (Ctrl+Alt+G brings it back)
    python coach.py --source-check   # counts and timings only, no chat content
    python coach.py --smoke          # opens the panel and closes it after 4 s (CI)
"""

from __future__ import annotations

import base64
import io
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import tkinter as tk
from tkinter import scrolledtext, simpledialog, ttk

import transcript as tr
from wechat_db import Session, WeChatDB, WeChatDBError

IS_WIN = sys.platform == "win32"
MODEL = "claude-opus-5-5"
HOTKEY_LABEL = "Ctrl+Alt+G"
ENGINES = {  # setting value → label in the panel
    "auto": "引擎：自动",
    "api": "Claude API Key",
    "claude": "Claude Code",
    "codex": "Codex",
}
WECHAT_EXES = {"weixin.exe", "wechat.exe", "wechatapp.exe"}


class CoachError(Exception):
    pass


class Refusal(CoachError):
    def __init__(self) -> None:
        super().__init__("这次请求被模型拒绝了，没有给出建议。")


# ---------------------------------------------------------------- settings & key


def _data_dir() -> Path:
    base = Path(os.environ.get("APPDATA", Path.home())) if IS_WIN else Path.home() / ".config"
    d = base / "WeChatCoach"
    d.mkdir(parents=True, exist_ok=True)
    return d


class Settings:
    path = _data_dir() / "settings.json"

    def __init__(self) -> None:
        try:
            self.data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.data = {}

    def save(self) -> None:
        self.path.write_text(json.dumps(self.data, ensure_ascii=False, indent=2), encoding="utf-8")

    @property
    def history(self) -> int:
        n = int(self.data.get("history") or 0)
        return min(n, 1000) if n > 0 else 150

    @property
    def effort(self) -> str:
        e = self.data.get("effort")
        return e if e in ("low", "medium", "high") else "medium"

    @property
    def engine(self) -> str:
        e = self.data.get("engine")
        return e if e in ENGINES else "auto"

    def note(self, key: str) -> str:
        return self.data.get("notes", {}).get(key, "")

    def set_note(self, key: str, note: str) -> None:
        notes = self.data.setdefault("notes", {})
        if note:
            notes[key] = note
        else:
            notes.pop(key, None)
        self.save()


class KeyStore:
    service, user = "WeChatCoach.anthropic", "api_key"

    @classmethod
    def load(cls) -> str | None:
        env = os.environ.get("ANTHROPIC_API_KEY")
        if env:
            return env
        try:
            import keyring

            return keyring.get_password(cls.service, cls.user) or None
        except Exception:
            return None

    @classmethod
    def save(cls, key: str) -> None:
        import keyring

        keyring.set_password(cls.service, cls.user, key)


# ---------------------------------------------------------------- system prompt


def load_system_prompt() -> str:
    if getattr(sys, "frozen", False):
        d = Path(sys._MEIPASS) / "prompt"  # type: ignore[attr-defined]
        files = sorted(p for p in d.glob("*.md"))
        import make_prompt

        return make_prompt.join([p.read_text(encoding="utf-8") for p in files])
    import make_prompt

    return make_prompt.load_from_sources()


# ---------------------------------------------------------------- WeChat window (Windows only)


class WeChatWindow:
    @staticmethod
    def find() -> int | None:
        """Largest visible top-level window owned by the WeChat process."""
        if not IS_WIN:
            return None
        import ctypes
        from ctypes import wintypes

        user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
        best: list = [None, 0]

        def exe_of(hwnd: int) -> str:
            pid = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            h = kernel32.OpenProcess(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
            if not h:
                return ""
            try:
                buf = ctypes.create_unicode_buffer(1024)
                size = wintypes.DWORD(1024)
                if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
                    return os.path.basename(buf.value).lower()
                return ""
            finally:
                kernel32.CloseHandle(h)

        @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        def cb(hwnd, _):
            if not user32.IsWindowVisible(hwnd) or user32.IsIconic(hwnd):
                return True
            r = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(r))
            w, h = r.right - r.left, r.bottom - r.top
            if w >= 400 and h >= 300 and w * h > best[1] and exe_of(hwnd) in WECHAT_EXES:
                best[0], best[1] = hwnd, w * h
            return True

        user32.EnumWindows(cb, 0)
        return best[0]

    @classmethod
    def capture_jpeg(cls, max_side: int = 1600) -> bytes:
        hwnd = cls.find()
        if not hwnd:
            raise CoachError("没找到微信窗口：请把微信聊天窗口留在屏幕上（不要最小化）。")
        import ctypes
        from ctypes import wintypes

        from PIL import ImageGrab

        r = wintypes.RECT()
        ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(r))
        img = ImageGrab.grab(bbox=(r.left, r.top, r.right, r.bottom), all_screens=True).convert("RGB")
        img.thumbnail((max_side, max_side))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=85)
        return buf.getvalue()

    @classmethod
    def activate(cls) -> None:
        hwnd = cls.find()
        if hwnd:
            import ctypes

            ctypes.windll.user32.SetForegroundWindow(hwnd)


def register_hotkey(callback) -> None:
    """Ctrl+Alt+G anywhere → callback() (runs on a background thread with its own message loop)."""
    if not IS_WIN:
        return

    def loop() -> None:
        import ctypes
        from ctypes import wintypes

        user32 = ctypes.windll.user32
        if not user32.RegisterHotKey(None, 1, 0x0002 | 0x0001 | 0x4000, ord("G")):  # CTRL|ALT|NOREPEAT
            return
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            if msg.message == 0x0312:  # WM_HOTKEY
                callback()

    threading.Thread(target=loop, daemon=True).start()


# ---------------------------------------------------------------- Claude backends


def text_content(text: str) -> list[dict]:
    return [{"type": "text", "text": text}]


def screenshot_content(jpeg: bytes, note: str) -> list[dict]:
    text = "这是我和对方的微信聊天截图，帮我看下一句怎么回。"
    if note.strip():
        text += f"\n背景补充：{note.strip()}"
    return [
        {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                     "data": base64.b64encode(jpeg).decode()}},
        {"type": "text", "text": text},
    ]


class APIConversation:
    """Anthropic API with the official SDK. History is append-only so the cached prefix stays valid."""

    def __init__(self, key: str, system: str, effort: str) -> None:
        import anthropic

        self.client = anthropic.Anthropic(api_key=key)
        self.system = system
        self.effort = effort
        self.messages: list[dict] = []

    def send(self, content: list[dict], on_text) -> str:
        import anthropic

        self.messages.append({"role": "user", "content": content})
        try:
            with self.client.beta.messages.stream(
                model=MODEL,
                max_tokens=16000,
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",  # a declined turn is re-run on a fallback model inside the same call
                output_config={"effort": self.effort},
                system=[{"type": "text", "text": self.system, "cache_control": {"type": "ephemeral"}}],
                messages=self.messages,
            ) as stream:
                for text in stream.text_stream:
                    on_text(text)
                final = stream.get_final_message()
        except anthropic.AuthenticationError as e:
            self.messages.pop()
            raise CoachError("API Key 无效，点「Key」重新填。") from e
        except anthropic.RateLimitError as e:
            self.messages.pop()
            raise CoachError("请求太频繁或额度不足，稍后再试。") from e
        except anthropic.APIStatusError as e:
            self.messages.pop()
            raise CoachError(f"API 请求失败（HTTP {e.status_code}）：{str(e.message)[:300]}") from e
        except anthropic.APIConnectionError as e:
            self.messages.pop()
            raise CoachError("连不上 api.anthropic.com，检查网络或代理。") from e
        if final.stop_reason == "refusal":
            self.messages.pop()
            raise Refusal()

        blocks = [b.model_dump(exclude_none=True) for b in final.content]
        # After a fallback, keep only what the serving model wrote (plus all text) and drop the markers.
        last_fb = max((i for i, b in enumerate(blocks) if b.get("type") == "fallback"), default=-1)
        blocks = [b for i, b in enumerate(blocks)
                  if (i > last_fb or b.get("type") == "text") and b.get("type") != "fallback"]
        self.messages.append({"role": "assistant", "content": blocks})
        return "".join(b.get("text", "") for b in blocks if b.get("type") == "text")

    def close(self) -> None:
        pass


class CLIConversation:
    """Keeps one `claude -p` process per conversation (uses the logged-in Claude Code subscription)."""

    def __init__(self, system: str, effort: str) -> None:
        exe = shutil.which("claude")
        if not exe:
            raise CoachError("没找到 claude 命令行。先装好 Claude Code 并登录，或点「Key」填 API Key。")
        work = Path(tempfile.gettempdir()) / "wechat-coach-cli"  # empty dir: no project CLAUDE.md gets loaded
        work.mkdir(exist_ok=True)
        sys_file = work / "system.md"
        sys_file.write_text(system, encoding="utf-8")
        flags = subprocess.CREATE_NO_WINDOW if IS_WIN else 0
        self.proc = subprocess.Popen(
            [exe, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
             "--include-partial-messages", "--verbose", "--system-prompt-file", str(sys_file),
             "--tools", "", "--model", "opus", "--effort", effort, "--no-session-persistence",
             "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands"],
            cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", bufsize=1, creationflags=flags,
        )

    @property
    def alive(self) -> bool:
        return self.proc.poll() is None

    def send(self, content: list[dict], on_text) -> str:
        if not self.alive:
            raise CoachError("claude 命令行已退出，请重新点「分析」")
        msg = {"type": "user", "message": {"role": "user", "content": content}}
        self.proc.stdin.write(json.dumps(msg, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        full = ""
        for line in self.proc.stdout:
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if obj.get("type") == "stream_event":
                ev = obj.get("event") or {}
                d = ev.get("delta") or {}
                if ev.get("type") == "content_block_delta" and d.get("type") == "text_delta":
                    full += d.get("text", "")
                    on_text(d.get("text", ""))
            elif obj.get("type") == "result":
                if obj.get("stop_reason") == "refusal":
                    raise Refusal()
                if obj.get("is_error"):
                    raise CoachError(obj.get("result") or "claude 命令行报错")
                return full
        raise CoachError("claude 命令行意外退出：" + (self.proc.stderr.read() or "")[:300])

    def close(self) -> None:
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        if self.alive:
            self.proc.terminate()


class CodexConversation:
    """OpenAI Codex CLI (`codex exec`, uses the logged-in ChatGPT plan). One process per turn; follow-ups
    resume the same Codex thread. Codex prints whole messages, so the reply appears when it is done."""

    def __init__(self, system: str, effort: str) -> None:
        self.exe = shutil.which("codex")
        if not self.exe:
            raise CoachError("没找到 codex 命令行。先装好 Codex（npm i -g @openai/codex）并运行 codex login。")
        self.work = Path(tempfile.gettempdir()) / "wechat-coach-codex"  # empty dir: no AGENTS.md gets loaded
        self.work.mkdir(exist_ok=True)
        sys_file = self.work / "system.md"
        sys_file.write_text(system, encoding="utf-8")
        self.config = [
            "-c", f'model_instructions_file="{sys_file.as_posix()}"',
            "-c", f'model_reasoning_effort="{effort}"',
            "-c", 'sandbox_mode="read-only"',
            "-c", 'approval_policy="never"',
        ]
        self.thread_id: str | None = None
        self.proc: subprocess.Popen | None = None

    alive = True

    def send(self, content: list[dict], on_text) -> str:
        text = "\n\n".join(b["text"] for b in content if b.get("type") == "text")
        images = []
        for i, b in enumerate(b for b in content if b.get("type") == "image"):
            img = self.work / f"shot{i}.jpg"
            img.write_bytes(base64.b64decode(b["source"]["data"]))
            images += ["-i", str(img)]
        if self.thread_id:
            cmd = [self.exe, "exec", "resume", self.thread_id]
        else:
            cmd = [self.exe, "exec"]
        cmd += ["--json", "--skip-git-repo-check", *self.config, *images, "-"]
        flags = subprocess.CREATE_NO_WINDOW if IS_WIN else 0
        self.proc = subprocess.Popen(cmd, cwd=self.work, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace",
                                     creationflags=flags)
        self.proc.stdin.write(text)  # via stdin: Windows caps command lines at ~32k characters
        self.proc.stdin.close()
        stderr: list[str] = []
        threading.Thread(target=lambda: stderr.extend(self.proc.stderr), daemon=True).start()
        replies: list[str] = []
        failure = ""
        for line in self.proc.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            kind = ev.get("type")
            if kind == "thread.started":
                self.thread_id = ev.get("thread_id") or self.thread_id
            elif kind == "item.completed" and (ev.get("item") or {}).get("type") == "agent_message":
                msg = ev["item"].get("text", "")
                on_text(("\n\n" if replies else "") + msg)
                replies.append(msg)
            elif kind == "turn.failed":
                failure = ((ev.get("error") or {}).get("message")) or "Codex 这一轮失败了"
            elif kind == "error":
                failure = ev.get("message") or failure
        code = self.proc.wait()
        if replies:
            return "\n\n".join(replies)
        detail = failure or "".join(stderr)[-300:] or f"退出码 {code}"
        if "401" in detail or "auth" in detail.lower() or "login" in detail.lower():
            raise CoachError("Codex 还没登录：在终端运行 codex login。")
        raise CoachError(f"Codex 出错：{detail[:300]}")

    def close(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


# ---------------------------------------------------------------- reply parsing ("▶ 稳｜text")


@dataclass(frozen=True)
class Reply:
    label: str
    text: str


def parse_replies(s: str, include_last_line: bool) -> list[Reply]:
    lines = s.split("\n")
    if not include_last_line:
        lines = lines[:-1]  # only complete lines, so half-streamed replies never show up as buttons
    out = []
    for raw in lines:
        line = raw.strip()
        if not line.startswith("▶"):
            continue
        body, label = line[1:].strip(), "推荐"
        for sep in ("｜", "|"):
            i = body.find(sep)
            if 0 <= i <= 6:
                label, body = body[:i].strip(), body[i + 1 :].strip()
                break
        body = body.strip("\"“”「」'")
        if body:
            out.append(Reply(label or "推荐", body))
    return out


# ---------------------------------------------------------------- the panel


CHIPS = {
    "更幽默": "再给 3 个更幽默、更有梗的回法。",
    "更自然像我": "这些太像教练写的了。照着我在记录里平时的说话习惯（长度、语气词、表情）重写 3 个版本。",
    "更直接": "给更直接、推进感更强的版本，但别油腻。",
    "TA 什么意思": "TA 最后这几条到底什么意思？兴趣怎么样？",
    "要不要约": "现在适合约 TA 吗？要约的话具体怎么约，给能直接发的话。",
    "先别回？": "我是不是应该先别回 / 晚点回？给我时机建议。",
}


class Coach:
    def __init__(self) -> None:
        self.settings = Settings()
        self.db = WeChatDB()
        self.db_ready = False
        self.system_prompt = load_system_prompt()
        self.running = False
        self.conversation = None
        self.spare: CLIConversation | None = None
        self.transcript = ""
        self.current = ""
        self.shown: list[Reply] = []
        self.sessions: list[Session] = []
        self.last_analyzed = 0
        self.pending_id = 0
        self.pending_since = 0.0
        self.auto_loop = False
        self.ui: queue.Queue = queue.Queue()

        self.root = tk.Tk()
        self.root.title("狗头军师 · 微信恋爱教练")
        self.root.attributes("-topmost", True)
        sw = self.root.winfo_screenwidth()
        self.root.geometry(f"440x700+{sw - 460}+20")
        self.root.minsize(340, 420)
        self.root.protocol("WM_DELETE_WINDOW", self.root.withdraw)  # keep running; hotkey brings it back
        self._build()
        self.root.after(50, self._drain)

    # -- threading helpers: worker threads never touch Tk directly

    def on_ui(self, fn, *a) -> None:
        self.ui.put((fn, a))

    def _drain(self) -> None:
        try:
            while True:
                fn, a = self.ui.get_nowait()
                fn(*a)
        except queue.Empty:
            pass
        self.root.after(50, self._drain)

    def bg(self, fn, *a) -> None:
        threading.Thread(target=fn, args=a, daemon=True).start()

    # -- layout

    def _build(self) -> None:
        f = ttk.Frame(self.root, padding=10)
        f.pack(fill="both", expand=True)

        row = ttk.Frame(f)
        row.pack(fill="x")
        self.contact = ttk.Combobox(row, state="readonly", values=["（读取聊天列表中…）"])
        self.contact.current(0)
        self.contact.bind("<<ComboboxSelected>>", lambda e: self.contact_changed())
        self.contact.pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="↻", width=3, command=lambda: self.bg(self.refresh_sessions)).pack(side="left", padx=4)
        self.source = ttk.Label(row, text="", foreground="gray")
        self.source.pack(side="left")

        self.note = ttk.Entry(f)
        self.note.pack(fill="x", pady=(8, 0))
        self.note.bind("<FocusOut>", lambda e: self.save_note())
        self.note.bind("<Return>", lambda e: self.save_note())
        self._placeholder(self.note, "关于 TA 的背景（按人保存）：怎么认识、到哪一步、你想要什么")

        act = ttk.Frame(f)
        act.pack(fill="x", pady=(8, 0))
        ttk.Button(act, text="分析", command=self.analyze).pack(side="left")
        self.auto = tk.BooleanVar(value=bool(self.settings.data.get("auto")))
        ttk.Checkbutton(act, text="她回了自动分析", variable=self.auto, command=self.toggle_auto).pack(side="left", padx=8)
        ttk.Button(act, text="Key", command=self.ask_key).pack(side="right")
        self.engine_box = ttk.Combobox(act, state="readonly", width=14, values=list(ENGINES.values()))
        self.engine_box.current(list(ENGINES).index(self.settings.engine))
        self.engine_box.bind("<<ComboboxSelected>>", lambda e: self.engine_changed())
        self.engine_box.pack(side="right", padx=6)

        self.status = ttk.Label(f, text=f"{HOTKEY_LABEL} 呼出面板，选好聊天后点「分析」", foreground="gray",
                                wraplength=400)
        self.status.pack(fill="x", pady=(8, 0))

        self.replies = ttk.Frame(f)
        self.replies.pack(fill="x", pady=(8, 0))

        self.output = scrolledtext.ScrolledText(f, wrap="word", height=14, font=("Microsoft YaHei UI", 10))
        self.output.configure(state="disabled")
        self.output.pack(fill="both", expand=True, pady=(8, 0))

        chips = ttk.Frame(f)
        chips.pack(fill="x", pady=(6, 0))
        for title in CHIPS:
            ttk.Button(chips, text=title, command=lambda t=title: self.ask(CHIPS[t])).pack(side="left", padx=1)

        ask = ttk.Frame(f)
        ask.pack(fill="x", pady=(6, 0))
        self.ask_entry = ttk.Entry(ask)
        self.ask_entry.pack(side="left", fill="x", expand=True)
        self.ask_entry.bind("<Return>", lambda e: self.ask_submitted())
        self._placeholder(self.ask_entry, "问军师 / 补充情况（回车发送）")
        ttk.Button(ask, text="新对话", command=self.new_conversation).pack(side="left", padx=(6, 0))

    @staticmethod
    def _placeholder(entry: ttk.Entry, text: str) -> None:
        entry.placeholder = text  # type: ignore[attr-defined]

        def show(_=None):
            if not entry.get():
                entry.insert(0, text)
                entry.configure(foreground="gray")

        def hide(_=None):
            if entry.get() == text and str(entry.cget("foreground")) == "gray":
                entry.delete(0, "end")
                entry.configure(foreground="")

        entry.bind("<FocusIn>", hide, add="+")
        entry.bind("<FocusOut>", show, add="+")
        show()

    @staticmethod
    def value(entry: ttk.Entry) -> str:
        v = entry.get()
        return "" if v == getattr(entry, "placeholder", None) else v.strip()

    def set_value(self, entry: ttk.Entry, v: str) -> None:
        entry.delete(0, "end")
        if v:
            entry.insert(0, v)
            entry.configure(foreground="")
        elif self.root.focus_get() is not entry:
            entry.insert(0, entry.placeholder)  # type: ignore[attr-defined]
            entry.configure(foreground="gray")

    def set_status(self, s: str) -> None:
        self.status.configure(text=s)

    def set_output(self, s: str) -> None:
        self.output.configure(state="normal")
        self.output.delete("1.0", "end")
        self.output.insert("end", s)
        self.output.see("end")
        self.output.configure(state="disabled")

    # -- contacts

    @property
    def selected(self) -> Session | None:
        i = self.contact.current()
        return self.sessions[i] if 0 <= i < len(self.sessions) and self.db_ready else None

    @property
    def note_key(self) -> str:
        s = self.selected
        return s.username if s else "_screenshot"

    def refresh_sessions(self) -> None:
        """Worker thread. Reloads the session list (most recent chat first)."""
        try:
            self.db.account()
            sessions = self.db.sessions()
        except Exception as e:  # WeChatDBError, OSError…
            self.db_ready = False
            msg = str(e)

            def screenshot_mode():
                self.source.configure(text="截图模式")
                self.contact.configure(values=["（读不了本地聊天记录，用截图）"])
                self.contact.current(0)
                self.load_note()
                self.set_status(msg + " 现在先用截图模式。")

            self.on_ui(screenshot_mode)
            return

        def apply():
            prev = self.selected.username if self.selected else None
            self.sessions = sessions[:60]
            self.db_ready = True
            self.source.configure(text="本地记录")
            self.contact.configure(values=[s.display_name + (f"  ·{s.unread_count} 未读" if s.unread_count else "")
                                           for s in self.sessions])
            idx = next((i for i, s in enumerate(self.sessions) if s.username == prev), 0)
            if self.sessions:
                self.contact.current(idx)
            self.load_note()
            if not self.running and self.selected:
                self.set_status(f"当前：{self.selected.display_name}，点「分析」开始（默认是最近聊天的人）")

        self.on_ui(apply)

    def load_note(self) -> None:
        self.set_value(self.note, self.settings.note(self.note_key))

    def save_note(self) -> None:
        self.settings.set_note(self.note_key, self.value(self.note))

    def contact_changed(self) -> None:
        self.load_note()
        self.last_analyzed = self.pending_id = 0
        self.set_status(f"已切换到 {self.selected.display_name if self.selected else ''}，点「分析」开始")

    # -- actions

    def summon(self) -> None:
        self.root.deiconify()
        self.root.lift()
        self.root.attributes("-topmost", True)
        if not self.running:
            self.bg(self.refresh_sessions)

    def ask_key(self) -> None:
        key = simpledialog.askstring("Anthropic API Key", "可选，不填就用 claude / codex 命令行。\n保存在 Windows 凭据管理器里，只发给 api.anthropic.com。",
                                     show="*", parent=self.root)
        if key and key.strip():
            try:
                KeyStore.save(key.strip())
                self.set_status("Key 已保存，点「分析」开始")
            except Exception as e:
                self.set_status(f"Key 保存失败：{e}")

    def copy_reply(self, r: Reply) -> None:
        self.root.clipboard_clear()
        self.root.clipboard_append(r.text)
        self.root.update()
        WeChatWindow.activate()  # jump back to WeChat so the user only has to press Ctrl+V and Enter
        self.set_status(f"已复制，到微信 Ctrl+V 发送：{r.text}")

    def toggle_auto(self) -> None:
        self.settings.data["auto"] = self.auto.get()
        self.settings.save()
        if not self.auto.get():
            self.set_status("自动分析已关闭")
            return
        if not self.db_ready:
            self.set_status("自动分析需要能读取本地聊天记录（现在是截图模式）")
            return
        self.pending_id = 0
        if not self.auto_loop:
            self.auto_loop = True
            self.root.after(3000, self.auto_tick)
        self.set_status(f"自动分析：{self.selected.display_name if self.selected else '当前对象'}发来新消息后自动分析")

    def auto_tick(self) -> None:
        """Analyzes once TA has sent something new and then paused for a few seconds."""
        if not self.auto.get():
            self.auto_loop = False
            return
        self.root.after(3000, self.auto_tick)
        s = self.selected
        if self.running or not s:
            return

        def check():
            try:
                msgs = self.db.messages(s.username, 1)
            except Exception:
                return
            if not msgs:
                return
            last = msgs[-1]

            def decide():
                if self.last_analyzed == 0:
                    self.last_analyzed = last.local_id  # don't spend a call on old history
                    return
                if last.is_send or last.local_id == self.last_analyzed:
                    self.pending_id = 0
                    return
                if last.local_id != self.pending_id:
                    self.pending_id, self.pending_since = last.local_id, time.time()
                    return
                if time.time() - self.pending_since >= 5 and not self.running:
                    self.analyze()

            self.on_ui(decide)

        self.bg(check)

    # -- analysis

    def resolved_engine(self) -> str:
        """auto: API Key if saved, else Claude Code, else Codex."""
        e = self.settings.engine
        if e != "auto":
            return e
        if KeyStore.load():
            return "api"
        if shutil.which("claude"):
            return "claude"
        return "codex" if shutil.which("codex") else "claude"

    def engine_changed(self) -> None:
        self.settings.data["engine"] = list(ENGINES)[self.engine_box.current()]
        self.settings.save()
        if self.spare and self.resolved_engine() != "claude":
            self.spare.close()
            self.spare = None
        self.prewarm()
        self.set_status(f"已切换到 {ENGINES[self.settings.engine]}，下次分析生效")

    def take_conversation(self):
        engine = self.resolved_engine()
        if engine == "api":
            key = KeyStore.load()
            if not key:
                raise CoachError("还没设置 API Key：点「Key」填一个，或把引擎换成 Claude Code / Codex。")
            return APIConversation(key, self.system_prompt, self.settings.effort)
        if engine == "codex":
            return CodexConversation(self.system_prompt, self.settings.effort)
        convo = self.spare if self.spare and self.spare.alive else CLIConversation(self.system_prompt, self.settings.effort)
        self.spare = None
        self.root.after(1000, self.prewarm)
        return convo

    def prewarm(self) -> None:
        if self.resolved_engine() != "claude" or (self.spare and self.spare.alive) or not shutil.which("claude"):
            return
        try:
            self.spare = CLIConversation(self.system_prompt, self.settings.effort)
        except CoachError:
            self.spare = None

    def analyze(self) -> None:
        self.summon_panel_only()
        if self.running:
            return
        self.running = True
        s, note, use_db = self.selected, self.value(self.note), self.db_ready
        self.save_note()

        def work():
            try:
                if use_db:
                    if not s:
                        raise CoachError("先在上方选一个聊天对象。")
                    self.on_ui(self.set_status, "读取聊天记录…")
                    msgs = self.db.messages(s.username, self.settings.history)
                    if not msgs:
                        raise CoachError(f"和 {s.display_name} 还没有聊天记录")
                    last_id = msgs[-1].local_id
                    self.on_ui(lambda: (setattr(self, "last_analyzed", last_id), setattr(self, "pending_id", 0)))
                    content = text_content(tr.transcript(msgs, s.display_name, note))
                    self.on_ui(self.set_status, f"分析和 {s.display_name} 的最近 {len(msgs)} 条消息…")
                else:
                    self.on_ui(self.set_status, "截取微信窗口…")
                    content = screenshot_content(WeChatWindow.capture_jpeg(), note)
                    self.on_ui(self.set_status, "分析截图中（截图模式只看当前一屏）…")
                self.run_turn(content, fresh=True)
            except Exception as e:
                self.on_ui(self.show_error, e)
            finally:
                self.on_ui(setattr, self, "running", False)

        self.bg(work)

    def summon_panel_only(self) -> None:
        self.root.deiconify()
        self.root.lift()

    def ask_submitted(self) -> None:
        q = self.value(self.ask_entry)
        if q:
            self.ask_entry.delete(0, "end")
            self.ask(q)

    def ask(self, question: str) -> None:
        if self.running:
            self.set_status("军师还在说，稍等…")
            return
        self.running = True
        note = self.value(self.note)

        def work():
            try:
                fresh = self.conversation is None
                text = question + (f"\n背景补充：{note}" if fresh and note else "")
                self.run_turn(text_content(text), fresh=fresh, question=question)
            except Exception as e:
                self.on_ui(self.show_error, e)
            finally:
                self.on_ui(setattr, self, "running", False)

        self.bg(work)

    def run_turn(self, content: list[dict], fresh: bool, question: str | None = None) -> None:
        """Worker thread. `fresh` starts a new conversation with the coach."""
        if fresh:
            if self.conversation:
                self.conversation.close()
            self.conversation = None
            self.conversation = self._on_ui_sync(self.take_conversation)

        def start():
            if fresh:
                self.transcript = ""
            if question is not None:
                self.transcript += ("\n\n" if self.transcript else "") + f"🙋 你：{question}\n\n"
            self.current = ""
            self.set_output(self.transcript)
            self.update_replies(final=False)
            self.set_status("军师思考中…")

        self.on_ui(start)
        t0 = time.time()
        final = self.conversation.send(content, lambda t: self.on_ui(self.append, t))

        def done():
            if final and final != self.current:  # a fallback model rewrote the turn: show what it served
                if self.transcript.endswith(self.current):
                    self.transcript = self.transcript[: len(self.transcript) - len(self.current)]
                self.transcript += final
                self.current = final
                self.set_output(self.transcript)
            self.update_replies(final=True)
            self.set_status(f"完成（{time.time() - t0:.0f} 秒）· 点上面的回复即复制，或继续追问")

        self.on_ui(done)

    def _on_ui_sync(self, fn):
        box: dict = {}
        ev = threading.Event()

        def run():
            try:
                box["v"] = fn()
            except Exception as e:
                box["e"] = e
            ev.set()

        self.on_ui(run)
        ev.wait()
        if "e" in box:
            raise box["e"]
        return box["v"]

    def new_conversation(self) -> None:
        if self.running:
            return
        if self.conversation:
            self.conversation.close()
        self.conversation = None
        self.transcript = self.current = ""
        self.set_output("")
        self.update_replies(final=True)
        self.set_status("已清空。点「分析」看聊天，或直接在下方提问")

    def append(self, text: str) -> None:
        self.current += text
        self.transcript += text
        self.output.configure(state="normal")
        self.output.insert("end", text)
        self.output.see("end")
        self.output.configure(state="disabled")
        if "\n" in text:
            self.update_replies(final=False)

    def update_replies(self, final: bool) -> None:
        replies = parse_replies(self.current, include_last_line=final)
        if not replies and self.current and self.shown:
            return  # a follow-up without new replies keeps the previous buttons
        if replies == self.shown:
            return
        self.shown = replies
        for w in self.replies.winfo_children():
            w.destroy()
        for r in replies:
            row = ttk.Frame(self.replies)
            row.pack(fill="x", pady=2)
            ttk.Button(row, text=r.label, width=5, command=lambda r=r: self.copy_reply(r)).pack(side="left", anchor="n")
            ttk.Label(row, text=r.text, wraplength=340, font=("Microsoft YaHei UI", 11)).pack(side="left", padx=6)

    def show_error(self, e: Exception) -> None:
        if isinstance(e, Refusal) and self.transcript.endswith(self.current):
            self.transcript = self.transcript[: len(self.transcript) - len(self.current)]
            self.current = ""
            self.set_output(self.transcript)
        self.set_status(str(e) or e.__class__.__name__)

    # -- run

    def run(self) -> None:
        if not KeyStore.load() and not shutil.which("claude") and not shutil.which("codex"):
            self.set_status("没有 API Key，也没找到 claude / codex 命令行：点「Key」填一个，或装好 Claude Code / Codex 并登录")
        register_hotkey(lambda: self.on_ui(self.summon))
        self.prewarm()
        self.bg(self.refresh_sessions)
        if self.auto.get():
            self.root.after(500, self.toggle_auto)
        try:
            self.root.mainloop()
        finally:
            for c in (self.conversation, self.spare):
                if c:
                    c.close()


def source_check() -> int:
    """Counts and timings only, no chat content."""
    db = WeChatDB()
    try:
        t = time.time()
        acct = db.account()
        print(f"[source] key ok (mode: {'pbkdf2' if acct.derive else 'raw'}) {time.time() - t:.2f}s")
        t = time.time()
        s = db.sessions()
        print(f"[source] {len(s)} private sessions ({time.time() - t:.2f}s)")
        if s:
            t = time.time()
            m = db.messages(s[0].username, Settings().history)
            print(f"[source] most recent chat: {len(m)} msgs ({time.time() - t:.2f}s), "
                  f"sent={sum(x.is_send for x in m)} received={sum(not x.is_send for x in m)}")
            lines = tr.transcript(m, "X", "").split("\n")
            print(f"[source] transcript: {len(lines)} lines, xml-leak lines="
                  f"{sum(('<' in l or 'CDATA' in l) for l in lines)}")
        return 0
    except WeChatDBError as e:
        print(f"[source] {e}")
        return 1


if __name__ == "__main__":
    if IS_WIN:
        try:  # crisp text and pixel-accurate window rects on high-DPI screens
            import ctypes

            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:
            pass
    for stream in (sys.stdout, sys.stderr):  # consoles on Windows may not be UTF-8
        if stream is not None and hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    if len(sys.argv) >= 2 and sys.argv[1] == "--source-check":
        sys.exit(source_check())
    app = Coach()
    if "--smoke" in sys.argv:  # CI: open the panel, then close it after a few seconds
        app.root.after(4000, app.root.destroy)
    app.run()
