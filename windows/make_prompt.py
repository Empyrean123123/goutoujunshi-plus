"""Assembles the coach's system prompt from the 狗头军师 knowledge base (shared with the macOS build).

    python make_prompt.py build/prompt     # copy the numbered prompt files (used by build.ps1 / CI)
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GTJS = ROOT / "goutoujunshi"
PRACTICAL = GTJS / "references" / "practical"

# Concatenated in this order at runtime (numbered so the order is the filename order).
FILES = [
    ("10-goutoujunshi.md", GTJS / "SKILL.md"),
    ("20-replies.md", PRACTICAL / "实战话术编排器：从一句回复到后续分支.md"),
    ("21-scene.md", PRACTICAL / "场景感、松弛感与社交校准：从接话到关系推进.md"),
    ("22-initiative.md", PRACTICAL / "主动表达、第一次见面与自然接触.md"),
    ("23-imbalance.md", PRACTICAL / "关系投入失衡：互惠判断、降级投入与退出决策.md"),
    ("90-realtime.md", ROOT / "prompts" / "realtime.md"),
]


def build(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for name, src in FILES:
        shutil.copyfile(src, out / name)
    print(f"prompt → {out} ({sum((out / n).stat().st_size for n, _ in FILES)} bytes)")


def join(texts: list[str]) -> str:
    return "\n\n---\n\n".join(texts)


def load_from_sources() -> str:
    return join([src.read_text(encoding="utf-8") for _, src in FILES])


if __name__ == "__main__":
    build(Path(sys.argv[1] if len(sys.argv) > 1 else "build/prompt"))
