#!/bin/bash
# Builds WeChatCoach.app from Sources/ and the 狗头军师 (goutoujunshi) skill.
set -euo pipefail
cd "$(dirname "$0")"
GTJS=../goutoujunshi
OLD=../HowToGetAlongWithGirls/.claude/skills/dating-coach  # optional, not in this repo
APP=build/WeChatCoach.app
RES="$APP/Contents/Resources"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES/prompt"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework ScreenCaptureKit -framework Vision -framework Carbon -framework Security \
  -lsqlite3 Sources/*.swift -o "$APP/Contents/MacOS/WeChatCoach"

# System prompt, concatenated in this order at runtime (numbered so the order is the filename order).
cp "$GTJS/SKILL.md"                                                   "$RES/prompt/10-goutoujunshi.md"
cp "$GTJS/references/practical/实战话术编排器：从一句回复到后续分支.md"       "$RES/prompt/20-replies.md"
cp "$GTJS/references/practical/场景感、松弛感与社交校准：从接话到关系推进.md"   "$RES/prompt/21-scene.md"
cp "$GTJS/references/practical/主动表达、第一次见面与自然接触.md"            "$RES/prompt/22-initiative.md"
cp "$GTJS/references/practical/关系投入失衡：互惠判断、降级投入与退出决策.md"   "$RES/prompt/23-imbalance.md"
[ -f "$OLD/references/signal-patterns.md" ] && cp "$OLD/references/signal-patterns.md" "$RES/prompt/30-signal-patterns.md"
cp ../prompts/realtime.md                                                "$RES/prompt/90-realtime.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.wechatcoach</string>
  <key>CFBundleName</key><string>WeChatCoach</string>
  <key>CFBundleExecutable</key><string>WeChatCoach</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>识别当前打开的微信聊天对象；WeFlow 不可用时截取聊天窗口</string>
</dict></plist>
PLIST
# Stable designated requirement so the screen-recording grant survives rebuilds (ad-hoc cdhash changes every build).
codesign --force --sign - --identifier local.wechatcoach -r='designated => identifier "local.wechatcoach"' "$APP"
echo "Built $APP ($(cat "$RES"/prompt/*.md | wc -c | tr -d ' ') bytes of prompt)"
