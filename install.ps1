# Merak for ComfyUI - one-line installer for Windows.
#
#   irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1 | iex
#
# With options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1))) -ApiKey "YOUR_KEY"
#
#   -ApiKey <key>     use this key instead of asking for one
#   -ComfyPath <dir>  your ComfyUI folder (or its custom_nodes folder)
#   -Lang en|zh       message language; the default follows your system
#   -Yes              never ask anything; stop with an error instead

param(
    [string]$ApiKey = "",
    [string]$ComfyPath = "",
    [string]$Lang = "",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "This installer needs Windows PowerShell 5 or newer (Windows 10 and 11 have it)." -ForegroundColor Red
    exit 1
}

$Repo = "snarkify/merak-comfyui-node"
$Branch = "main"
$NodeDirName = "merak-comfyui-node"
$KeyDir = Join-Path $HOME ".merak"
$KeyFile = Join-Path $KeyDir "api_key"

if (-not $Lang) {
    $Lang = if ((Get-Culture).Name -like "zh*") { "zh" } else { "en" }
}
$Interactive = (-not $Yes) -and ([Environment]::UserInteractive)

function T([string]$en, [string]$zh) { if ($Lang -eq "zh") { $zh } else { $en } }
function Say([string]$en, [string]$zh) { Write-Host (T $en $zh) }
function Die([string]$en, [string]$zh) { Write-Host (T $en $zh) -ForegroundColor Red; exit 1 }
function Ask([string]$en, [string]$zh) {
    if (-not $Interactive) { return "" }
    return (Read-Host (T $en $zh))
}

Say "" ""
Say "  Merak for ComfyUI - installer" "  Merak for ComfyUI 安装程序"
Say "  ------------------------------" "  ------------------------------"

# ---------------------------------------------------------------- find ComfyUI

$found = New-Object System.Collections.ArrayList

function Note([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return }
    $dir = $dir.TrimEnd('\', '/')
    if (-not ($dir -match '[\\/]custom_nodes$')) { $dir = Join-Path $dir "custom_nodes" }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    $full = (Resolve-Path -LiteralPath $dir).Path
    if ($found -notcontains $full) { [void]$found.Add($full) }
}

if ($ComfyPath) {
    Note $ComfyPath
    if ($found.Count -eq 0) {
        Die "No custom_nodes folder under: $ComfyPath" "在该路径下找不到 custom_nodes 文件夹：$ComfyPath"
    }
}
else {
    if ($env:COMFYUI_PATH) { Note $env:COMFYUI_PATH }
    # The places ComfyUI Desktop, the portable build and a git clone normally land.
    # GetFolderPath follows a OneDrive redirection of Documents or Desktop.
    $docs = [Environment]::GetFolderPath("MyDocuments")
    $desktop = [Environment]::GetFolderPath("Desktop")
    Note (Join-Path $docs "ComfyUI")
    Note (Join-Path $HOME "ComfyUI")
    Note (Join-Path $desktop "ComfyUI")
    Note (Join-Path $desktop "ComfyUI_windows_portable\ComfyUI")
    Note (Join-Path $HOME "Downloads\ComfyUI")
    Note (Join-Path $HOME "Downloads\ComfyUI_windows_portable\ComfyUI")
    Note "C:\ComfyUI"
    Note "C:\ComfyUI_windows_portable\ComfyUI"
    Note "D:\ComfyUI"
    Note "D:\ComfyUI_windows_portable\ComfyUI"

    if ($found.Count -eq 0) {
        Say "Looking for ComfyUI on this computer..." "正在查找本机上的 ComfyUI……"
        $roots = @($HOME, $docs, $desktop, (Join-Path $HOME "Downloads"), "C:\", "D:\")
        foreach ($root in ($roots | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 3 -Filter "custom_nodes" -ErrorAction SilentlyContinue |
                ForEach-Object { Note $_.FullName }
        }
    }
}

if ($found.Count -eq 0) {
    Say "ComfyUI was not found on this computer." "在本机上没有找到 ComfyUI。"
    $answer = Ask "Type the full path to your ComfyUI folder (or press Enter to stop)" `
                  "请输入 ComfyUI 文件夹的完整路径（直接回车则退出）"
    if ($answer) { Note $answer }
}

if ($found.Count -eq 0) {
    Say "Install ComfyUI first - see https://github.com/$Repo#install-comfyui - then run this again." `
        "请先安装 ComfyUI（见 https://github.com/$Repo/blob/main/README.zh-CN.md#安装-comfyui），然后重新运行本脚本。"
    exit 1
}

if ($found.Count -eq 1) {
    $target = $found[0]
}
else {
    Say "Several ComfyUI installs were found:" "找到多个 ComfyUI 安装位置："
    for ($i = 0; $i -lt $found.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $found[$i]) }
    $choice = Ask "Which one? [1]" "选择哪一个？[1]"
    $index = 1
    if ($choice -match '^\d+$') { $index = [int]$choice }
    if ($index -lt 1 -or $index -gt $found.Count) { $index = 1 }
    $target = $found[$index - 1]
}

Say "ComfyUI: $(Split-Path $target -Parent)" "ComfyUI 位置：$(Split-Path $target -Parent)"

# ------------------------------------------------------------------ the files

$dest = Join-Path $target $NodeDirName
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("merak-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    Say "Downloading the node..." "正在下载节点……"
    $zip = Join-Path $work "node.zip"
    try {
        Invoke-WebRequest -Uri "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" -OutFile $zip -UseBasicParsing
    }
    catch {
        Die "Download failed - check your internet connection and try again." "下载失败 —— 请检查网络连接后重试。"
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $work -Force

    $src = Join-Path $work "$NodeDirName-$Branch"
    if (-not (Test-Path -LiteralPath (Join-Path $src "merak_nodes.py"))) {
        $src = (Get-ChildItem -LiteralPath $work -Directory | Where-Object { Test-Path (Join-Path $_.FullName "merak_nodes.py") } | Select-Object -First 1).FullName
    }
    if (-not $src -or -not (Test-Path -LiteralPath (Join-Path $src "merak_nodes.py"))) {
        Die "The download looks incomplete." "下载的文件不完整。"
    }

    if (Test-Path -LiteralPath $dest) {
        $backup = "$dest.previous"
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
        Move-Item -LiteralPath $dest -Destination $backup
        Say "Replacing the previous version (kept as $NodeDirName.previous)." `
            "已替换旧版本（旧版本保留为 $NodeDirName.previous）。"
    }
    Move-Item -LiteralPath $src -Destination $dest
    Say "Installed to $dest" "已安装到 $dest"
}
catch {
    Die "Install failed: $($_.Exception.Message)" "安装失败：$($_.Exception.Message)"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------------- the key

$haveKey = (Test-Path -LiteralPath $KeyFile) -and ((Get-Content -LiteralPath $KeyFile -Raw -ErrorAction SilentlyContinue).Trim())
if (-not $ApiKey -and $haveKey) {
    Say "An API key is already saved in $KeyFile - keeping it." "$KeyFile 中已保存 API key —— 保持不变。"
}
else {
    if (-not $ApiKey) {
        $ApiKey = Ask "Paste your merak API key (from https://merakcompute.ai)" `
                      "请粘贴你的 merak API key（在 https://merakcompute.ai 获取）"
    }
    $ApiKey = ($ApiKey -replace '\s', '')
    if ($ApiKey) {
        New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null
        # No BOM: the node reads this file as plain UTF-8 text.
        [System.IO.File]::WriteAllText($KeyFile, $ApiKey + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Say "Key saved to $KeyFile" "Key 已保存到 $KeyFile"
    }
    else {
        Say "No key saved. Save one later by putting it in $KeyFile" "未保存 key。之后可将 key 写入 $KeyFile"
    }
}

# ------------------------------------------------------------------- finished

Say "" ""
Say "Done. Restart ComfyUI, double-click the canvas and search for `"Merak`"." `
    "完成。请重启 ComfyUI，然后双击画布并搜索 “Merak”。"
Say "You should see: Merak Generate Video, Merak Fetch Video (by id)." `
    "你应该能看到：Merak Generate Video、Merak Fetch Video (by id)。"
Say "" ""
