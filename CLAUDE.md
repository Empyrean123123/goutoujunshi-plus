# 给 AI 的部署说明（与 AGENTS.md 相同）

用户让你“部署这个项目”时，照下面做，目标是在**用户自己的电脑上**装好 WeChatCoach（微信旁边的恋爱军师悬浮窗）并能读取本地聊天记录。每一步做完都检查结果，失败就按对应的分支处理，不要跳步。

## 规则

- 只处理**这台电脑上用户本人登录的微信**。不要读取、导出或打印任何聊天内容；检查一律用 `--source-check`（只输出条数和耗时）。
- 微信数据库密钥和 API Key 是秘密：不要回显到对话里，不要写进仓库、日志或任何文件，不要发往网络。只能通过下面的命令保存（存在系统凭据管理器 / 钥匙串里）。
- 下载并运行任何第三方程序（Python 安装包、取密钥工具等）之前，先告诉用户是什么、从哪下载，得到同意再做。
- 不要修改微信本身的文件。

## Windows

1. **Python**：`py -3.12 --version`。没有就征得同意后安装：`winget install -e --id Python.Python.3.12`。
2. **代码与依赖**（在仓库的 `windows` 目录里）：
   ```powershell
   py -3.12 -m venv .venv
   .\.venv\Scripts\python -m pip install -r requirements.txt
   ```
3. **检查聊天记录能否读取**：`.\.venv\Scripts\python coach.py --source-check`，看退出码：
   - `0`：可以读取，跳到第 5 步。
   - `2`（输出里有 `NEED_KEY`）：找到了微信数据，但缺数据库密钥，去第 4 步。
   - `1`：读不到。没找到 `xwechat_files` 时，请用户确认微信 4.x 已登录过、数据目录在哪；如果在别处，把那个目录追加到 `%APPDATA%\WeChatCoach\settings.json` 的 `wechatDirs` 数组里，然后重试。
4. **取得数据库密钥**（目标：让用户只点一次「同意」）。按顺序尝试，成功一个就停：
   1. 这台电脑上用 WeFlow 取过密钥的话，第 3 步会自动用上，不需要做什么。
   2. 否则，**由你（部署 AI）自动完成取密钥**，而不是让用户去找工具：
      - 先一句话告诉用户：接下来会下载一个开源的微信取密钥小工具、在本机运行一次来取出**他本人账号**的数据库密钥，密钥只存在本机凭据管理器、不外发；问他是否同意。**等到用户明确说「同意 / 可以 / 好」再往下做**（这是整个部署里唯一需要用户点头的地方）。
      - 得到同意后：确认微信开着并已登录 → 选一个开源、支持 WeFlow「外部密钥工具」协议（stdin 一行 JSON 请求，stdout 输出 NDJSON，末行 `{"type":"result","success":true,"key":"…"}`）的取密钥工具，下载到临时目录 → `.\.venv\Scripts\python coach.py --key-provider <工具路径>`。
      - 工具若要求重启微信或管理员权限，照它的提示让用户配合一次。
      - 该工具只能用于读取**用户本人登录的账号**；不要用它去碰别的账号或别人的数据。
   3. 用户手里已经有现成的工具或 64 位十六进制密钥：直接 `--key-provider <工具>` 或 `--set-key <密钥>`（`--set-key` 让用户自己在终端敲，或你代敲但不要把密钥复述出来）。

   都失败时，告诉用户先用截图模式（不需要密钥，只分析当前一屏），并说明卡在哪一步。拿到密钥后重新执行第 3 步，直到退出码为 `0`。
5. **AI 引擎**（用户已经能用的那个即可）：
   - 装了 Claude Code 且已登录（`claude --version` 能运行）：`coach.py --engine claude`
   - 装了 Codex 且已登录（`codex login status`）：`coach.py --engine codex`
   - 有 Anthropic API Key：`coach.py --engine api`，然后请用户在面板里点「Key」自己填写。
   - 不确定：`coach.py --engine auto`（有 Key 用 Key，否则用 Claude Code，再否则用 Codex）。
6. **启动**：`.\.venv\Scripts\pythonw coach.py`（不显示命令行窗口）。告诉用户按 **Ctrl+Alt+G** 呼出面板，选好聊天对象后点「分析」。
   - 可选：征得同意后，在桌面建一个快捷方式，目标是 `<仓库>\windows\.venv\Scripts\pythonw.exe "<仓库>\windows\coach.py"`。
   - 可选：打包成单个 exe：`.\.venv\Scripts\pip install pyinstaller; .\build.ps1`，产物是 `dist\WeChatCoach.exe`。

## macOS

```bash
cd mac && ./build.sh && open build/WeChatCoach.app
```
第一次运行时，需要用户同意钥匙串和屏幕录制权限（这两步只能用户自己点）。读取聊天记录用的是 WeFlow 存下的密钥；没有的话会自动改用截图模式。

## 部署完成后告诉用户

- 能否读取本地记录（`--source-check` 的条数），用的是哪个引擎。
- 如果只能用截图模式，说明原因和补救办法（第 4 步）。
