# goutoujunshi-plus · 狗头军师微信恋爱教练

微信旁边的悬浮窗：按快捷键呼出，读取你和 TA 的最近聊天记录（只在本机读取），由「狗头军师」分析局势，并给出能直接发的回复。点一下就能复制，然后切回微信。

支持 **macOS** 和 **Windows**（微信 4.x）。

## 工作原理

1. 微信 4.x 的聊天数据库是加密的。这里用 [WeFlow](https://github.com/hicccc77/WeFlow) 之前取到的数据库密钥，在**内存里**解密，只读，不往磁盘写，也不改微信的数据。
2. 把最近 N 条消息（默认 150）整理成文字记录，连同「狗头军师」知识库（`goutoujunshi/`）一起发给 Claude。
3. 回复里 `▶ 标签｜内容` 这样的行会变成按钮，点了就复制并切回微信。

读不到本地记录时，自动改用截图模式：截取微信窗口发给 Claude。

## Windows

需要先装好 WeFlow，并在里面取到当前微信账号的密钥。

**直接用**：在本仓库的 Actions → windows → 最新一次运行 → Artifacts 里下载 `WeChatCoach-windows`，解压得到 `WeChatCoach.exe`。

**从源码运行**：

```powershell
cd windows
py -3.12 -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python coach.py --source-check   # 只输出条数和耗时，不输出聊天内容
python coach.py
```

打包：`pip install pyinstaller; .\build.ps1` → `windows\dist\WeChatCoach.exe`

- 快捷键 **Ctrl+Alt+G** 呼出面板。关掉窗口后程序仍在后台运行。
- 默认选中最近聊过的人，也可以在下拉框里换别人。
- API Key 保存在 Windows 凭据管理器里；不填 Key 时，使用已登录的 `claude` 命令行（Claude Code 订阅）。
- 设置和每个人的背景备注保存在 `%APPDATA%\WeChatCoach\settings.json`，可改 `history`（条数）和 `effort`（low / medium / high）。

## macOS

```bash
cd mac && ./build.sh && open build/WeChatCoach.app
```

快捷键 **⌥⌘G**。第一次运行会请求钥匙串（读取 WeFlow 密钥）和屏幕录制（识别当前打开的聊天）权限。

## 目录

| 路径 | 内容 |
|---|---|
| `windows/` | Windows 版（Python + tkinter）：`wechat_db.py` 解密读库，`coach.py` 悬浮窗 |
| `mac/` | macOS 版（Swift / AppKit） |
| `goutoujunshi/` | 狗头军师知识库，基于 [shengjidaguai-china/goutoujunshi](https://github.com/shengjidaguai-china/goutoujunshi)（MIT，见 `goutoujunshi/LICENSE`） |
| `prompts/realtime.md` | 悬浮窗实时模式的附加提示词 |

## 隐私

聊天记录只在本机解密。只有你点「分析」（或开启自动分析）时，最近的记录才会发给 Anthropic API 或 `claude` 命令行。只读取你自己登录的微信账号的数据。
