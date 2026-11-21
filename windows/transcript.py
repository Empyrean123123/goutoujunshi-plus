"""Turns WeChat messages into the plain-text transcript the coach reads (port of WeFlow.describe/transcript)."""

from __future__ import annotations

import re
import time
from datetime import datetime

from wechat_db import Message

_WEEK = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


def _xml(s: str, tag: str) -> str | None:
    m = re.search(rf"<{tag}>([\s\S]*?)</{tag}>", s)
    if not m:
        return None
    v = m.group(1).replace("<![CDATA[", "").replace("]]>", "")
    for a, b in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&apos;", "'"), ("&amp;", "&")):
        v = v.replace(a, b)
    v = v.strip()
    return v or None


def _clip(s: str, n: int = 300) -> str:
    one = s.replace("\n", " ")
    return one[:n] + "…" if len(one) > n else one


def describe(m: Message) -> str | None:
    raw = m.content
    text = raw.replace("\n", " ").strip()
    t = m.type
    if t == 1:
        return _clip(text) if text else None
    simple = {3: "[图片]", 34: "[语音]", 43: "[视频]", 47: "[表情]", 42: "[名片]", 50: "[语音/视频通话]"}
    if t in simple:
        return simple[t]
    if t == 48:
        return "[位置] " + _clip(_xml(raw, "label") or _xml(raw, "poiname") or "", 60)
    if t == 49:
        title = _clip(_xml(raw, "title") or "", 200)
        try:
            sub = int(_xml(raw, "type") or 0)
        except ValueError:
            sub = 0
        if sub == 57:
            q = _xml(raw, "content")
            quoted = "" if not q or "<" in q else f"（引用：{_clip(q, 60)}）"
            return title + quoted
        named = {5: "[链接]", 6: "[文件]", 19: "[聊天记录]", 2001: "[红包]", 33: "[小程序]", 36: "[小程序]",
                 51: "[视频号]", 3: "[音乐]", 4: "[视频链接]"}
        if sub == 2000:
            return f"[转账] {_xml(raw, 'feedesc') or ''}"
        if sub == 62:
            return "[拍一拍]"
        if sub in named:
            return f"{named[sub]} {title}"
        return f"[分享] {title}" if title else "[分享]"
    if t in (10000, 10002):
        plain = (_xml(raw, "content") or _xml(raw, "replacemsg") or "") if "<" in raw else text
        cleaned = re.sub(r"<[^>]+>", "", plain)
        return f"（系统提示：{_clip(cleaned, 80)}）" if cleaned else None
    if raw.startswith("<") or not text:
        return "[其他消息]"
    return _clip(text, 200)


def _day(ts: float) -> str:
    d = datetime.fromtimestamp(ts)
    return f"{d.month}月{d.day}日 {_WEEK[d.weekday()]}"


def transcript(msgs: list[Message], name: str, note: str) -> str:
    out = f"聊天对象：{name}（下面「对方」就是 TA）\n"
    if note:
        out += f"背景补充：{note}\n"
    out += f"\n最近 {len(msgs)} 条微信消息，按时间从早到晚：\n"
    last_day = ""
    for m in msgs:
        body = describe(m)
        if body is None:
            continue
        d = _day(m.create_time)
        if d != last_day:
            out += f"\n—— {d} ——\n"
            last_day = d
        out += f"{datetime.fromtimestamp(m.create_time):%H:%M} {'我' if m.is_send else '对方'}：{body}\n"
    now = time.time()
    out += f"\n现在是 {_day(now)} {datetime.fromtimestamp(now):%H:%M}。"
    if msgs:
        last = msgs[-1]
        secs = int(now) - last.create_time
        ago = f"{max(secs // 60, 0)} 分钟" if secs < 3600 else (f"{secs // 3600} 小时" if secs < 86400 else f"{secs // 86400} 天")
        out += f"最后一条是{'我' if last.is_send else '对方'}发的，距今约 {ago}。"
        out += "对方还没回。帮我判断要不要再发、发什么、什么时候发。" if last.is_send else "帮我看下一句怎么回。"
    return out
