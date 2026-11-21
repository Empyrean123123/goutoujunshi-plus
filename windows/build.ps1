# Builds dist\WeChatCoach.exe (one file, no console). Run from this folder in PowerShell:
#   py -3.12 -m venv .venv; .\.venv\Scripts\Activate.ps1; pip install -r requirements.txt pyinstaller; .\build.ps1
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true  # a failing python/pyinstaller step stops the build
Set-Location $PSScriptRoot
python make_prompt.py build\prompt
pyinstaller --noconfirm --onefile --windowed --name WeChatCoach `
  --add-data "build\prompt;prompt" `
  --hidden-import keyring.backends.Windows `
  coach.py
Write-Host "Built dist\WeChatCoach.exe"
