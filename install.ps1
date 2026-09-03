# Merak for ComfyUI - installer for Windows.
#
#   irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1 | iex
#
# From the Command Prompt, install.cmd fetches this file and runs it.
# macOS and Linux have the same installer as install.sh - all three are kept in
# step by tests/detect_test.sh.
#
# With options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1))) -ApiKey "YOUR_KEY"
#
#   -ApiKey <key>     use this key instead of asking for one
#   -ComfyPath <dir>  your ComfyUI folder (or its custom_nodes folder)
#   -Lang en|zh       message language; the default follows your system
#   -Yes              never ask anything; stop with an error instead
#   -NoScan           skip the disk search, use only recorded and default paths
#   -DetectOnly       print every ComfyUI folder found, then stop

param(
    [string]$ApiKey = "",
    [string]$ComfyPath = "",
    [string]$Lang = "",
    [switch]$Yes,
    [switch]$NoScan,
    [switch]$DetectOnly
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
$KeyDir = [System.IO.Path]::Combine($HOME, ".merak")
$KeyFile = [System.IO.Path]::Combine($KeyDir, "api_key")

if (-not $Lang) {
    $Lang = if ((Get-Culture).Name -like "zh*") { "zh" } else { "en" }
}
$Interactive = (-not $Yes) -and ([Environment]::UserInteractive)

# Note: PowerShell reads the typographic quotes as string delimiters, so the
# Chinese messages are single-quoted and carry none of them.
function T([string]$en, [string]$zh) { if ($Lang -eq "zh") { $zh } else { $en } }
function Say([string]$en, [string]$zh) { Write-Host (T $en $zh) }
function Die([string]$en, [string]$zh) { Write-Host (T $en $zh) -ForegroundColor Red; exit 1 }
function Ask([string]$en, [string]$zh) {
    if (-not $Interactive) { return "" }
    return (Read-Host (T $en $zh))
}

Say "" ""
Say "  Merak for ComfyUI - installer" '  Merak for ComfyUI 安装程序'
Say "  ------------------------------" "  ------------------------------"

# --------------------------------------------------------------- finding it
#
# ComfyUI does not live in one place across systems, but every install has the
# same shape inside: <base>\custom_nodes, next to main.py or comfyui_version.py.
# So the search is for that shape, cheapest source first - the desktop app and
# comfy-cli both write down where they put it, which beats searching a disk.

$sure = New-Object System.Collections.ArrayList   # folders confirmed to be a ComfyUI install
$maybe = New-Object System.Collections.ArrayList  # folders that hold custom_nodes but look less certain

function Combine([string]$a, [string]$b) {
    # Not Join-Path: that resolves the drive, and throws on a D:\ path when the
    # machine has no D: drive. This is plain string arithmetic.
    return [System.IO.Path]::Combine($a, $b)
}

function Test-ComfyRoot([string]$dir) {
    return (Test-Path -LiteralPath (Combine $dir "main.py")) -or
           (Test-Path -LiteralPath (Combine $dir "comfyui_version.py")) -or
           (Test-Path -LiteralPath (Combine $dir "comfy") -PathType Container)
}

function Note([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return }
    $dir = $dir.Trim().TrimEnd('\', '/')
    if (-not ($dir -match '[\\/]custom_nodes$')) { $dir = Combine $dir "custom_nodes" }
    # Never offer our own folder, or a backup of it, as a place to install into.
    # Whole path segments only: a parent folder that merely contains the name in
    # the middle of its own is somebody else's business.
    $segments = $dir -split '[\\/]'
    if (($segments -contains $NodeDirName) -or ($segments | Where-Object { $_ -like '*.previous' })) { return }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    try { $full = (Resolve-Path -LiteralPath $dir).Path } catch { return }
    $root = Split-Path $full -Parent
    if (Test-ComfyRoot $root) {
        if ($sure -notcontains $full) { [void]$sure.Add($full) }
    }
    elseif (($sure -notcontains $full) -and ($maybe -notcontains $full)) {
        [void]$maybe.Add($full)
    }
}

function NoteBase([string]$dir) { # the desktop records the parent of the ComfyUI folder
    Note $dir
    if (-not [string]::IsNullOrWhiteSpace($dir)) { Note (Combine $dir "ComfyUI") }
}

function FoundAny { return ($sure.Count + $maybe.Count) -gt 0 }

function Children([string]$dir) { # one folder per install, under a parent the app records
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    return (Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

# 1. What the caller told us, or the environment.
if ($ComfyPath) {
    NoteBase $ComfyPath
    if (-not (FoundAny)) {
        Die "No custom_nodes folder under: $ComfyPath" "在该路径下找不到 custom_nodes 文件夹：$ComfyPath"
    }
}
else {
    if ($env:COMFYUI_PATH) { NoteBase $env:COMFYUI_PATH }

    # 2. Paths the ComfyUI apps write down for themselves.
    $confDirs = @()
    if ($env:APPDATA) {
        $confDirs += (Combine $env:APPDATA "Comfy Desktop")   # desktop 2
        $confDirs += (Combine $env:APPDATA "ComfyUI")         # desktop 1
    }
    $confDirs += (Combine $HOME ".config/comfyui-desktop-2")
    $confDirs += (Combine $HOME ".config/ComfyUI")

    foreach ($conf in $confDirs) {
        if (-not (Test-Path -LiteralPath $conf -PathType Container)) { continue }

        # Desktop 2: every install it made, by path, plus the folder it keeps them in.
        $installs = Combine $conf "installations.json"
        if (Test-Path -LiteralPath $installs) {
            try {
                $records = Get-Content -LiteralPath $installs -Raw | ConvertFrom-Json
                foreach ($record in @($records)) {
                    if ($record.installPath) { NoteBase $record.installPath }
                }
            }
            catch { }
        }
        $settings = Combine $conf "settings.json"
        if (Test-Path -LiteralPath $settings) {
            try {
                $parsed = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
                if ($parsed.installDir) {
                    foreach ($child in (Children $parsed.installDir)) { NoteBase $child }
                }
            }
            catch { }
        }

        # Desktop 1: one base path, in JSON and again in YAML.
        $config = Combine $conf "config.json"
        if (Test-Path -LiteralPath $config) {
            try {
                $parsed = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
                if ($parsed.basePath) { NoteBase $parsed.basePath }
            }
            catch { }
        }
        $yaml = Combine $conf "extra_models_config.yaml"
        if (Test-Path -LiteralPath $yaml) {
            Get-Content -LiteralPath $yaml -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^\s*base_path:\s*(.+?)\s*$' } |
                ForEach-Object { NoteBase $Matches[1] }
        }
    }

    # 3. comfy-cli remembers the workspace it installed into.
    foreach ($ini in @((Combine $HOME ".config/comfy-cli/config.ini"),
                       (Combine $env:APPDATA "comfy-cli/config.ini"))) {
        if ($ini -and (Test-Path -LiteralPath $ini)) {
            Get-Content -LiteralPath $ini -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^\s*(default_workspace|recent_workspace)\s*=\s*(.+?)\s*$' } |
                ForEach-Object { NoteBase $Matches[2] }
        }
    }

    # 4. A ComfyUI that is running right now says where it is.
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'main\.py' } |
            ForEach-Object {
                if ($_.CommandLine -match '["'']?([A-Za-z]:[\\/][^"'']*?)[\\/]main\.py') { NoteBase $Matches[1] }
            }
    }
    catch { }

    # 5. Where the desktop app, the portable build and a plain clone land by default.
    $docs = [Environment]::GetFolderPath("MyDocuments")
    $desktop = [Environment]::GetFolderPath("Desktop")
    $bases = @(
        (Combine $HOME "ComfyUI-Installs"),
        (Combine $docs "ComfyUI"),
        (Combine $HOME "Documents/ComfyUI"),
        (Combine $HOME "ComfyUI"),
        (Combine $desktop "ComfyUI"),
        (Combine $desktop "ComfyUI_windows_portable/ComfyUI"),
        (Combine $HOME "Downloads/ComfyUI"),
        (Combine $HOME "Downloads/ComfyUI_windows_portable/ComfyUI"),
        "C:\ComfyUI", "C:\ComfyUI_windows_portable\ComfyUI",
        "D:\ComfyUI", "D:\ComfyUI_windows_portable\ComfyUI"
    )
    if ($env:LOCALAPPDATA) {
        $bases += (Combine $env:LOCALAPPDATA "Comfy-Desktop/ComfyUI-Installs")
        $bases += (Combine $env:LOCALAPPDATA "Programs/ComfyUI")
    }
    foreach ($base in $bases) {
        NoteBase $base
        foreach ($child in (Children $base)) { NoteBase $child }
    }

    # 6. Windows keeps no file index a script can query, so the fallback is a walk.
    #    It is depth-limited and prunes the folders that hold nothing but packages,
    #    which keeps it to seconds on a normal machine rather than minutes.
    if ((-not (FoundAny)) -and (-not $NoScan)) {
        Say "Searching your folders for ComfyUI (this can take a minute)..." '正在搜索 ComfyUI（可能需要一分钟）……'
        $skip = 'node_modules|\\\.git$|site-packages|\\AppData\\Local\\Temp|\\Windows\\|\\Program Files|\\\$Recycle'
        $roots = @($HOME, $docs, $desktop, (Combine $HOME "Downloads"), "C:\", "D:\") | Select-Object -Unique
        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 4 -Filter "custom_nodes" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch $skip } |
                ForEach-Object { Note $_.FullName }
            if (FoundAny) { break }
        }
    }
}

$all = @($sure) + @($maybe)

if ($DetectOnly) {
    foreach ($item in $sure) { Write-Host ("found " + (Split-Path $item -Parent)) }
    foreach ($item in $maybe) { Write-Host ("maybe " + (Split-Path $item -Parent)) }
    exit 0
}

if ($all.Count -eq 0) {
    Say "ComfyUI was not found on this computer." '在本机上没有找到 ComfyUI。'
    $answer = Ask "Type the full path to your ComfyUI folder (or press Enter to stop)" `
                  '请输入 ComfyUI 文件夹的完整路径（直接回车则退出）'
    if ($answer) { NoteBase $answer }
    $all = @($sure) + @($maybe)
}

if ($all.Count -eq 0) {
    Say "Install ComfyUI first - see https://github.com/$Repo#install-comfyui - then run this again." `
        "请先安装 ComfyUI（见 https://github.com/$Repo/blob/main/README.zh-CN.md#安装-comfyui），然后重新运行本脚本。"
    exit 1
}

if ($all.Count -eq 1) {
    $target = $all[0]
    if ($sure.Count -ne 1) {
        # A custom_nodes folder with no ComfyUI beside it - worth a confirmation.
        Say ("Found: " + (Split-Path $target -Parent)) ('找到：' + (Split-Path $target -Parent))
        $reply = Ask "This does not look like a full ComfyUI folder. Install there anyway? [y/N]" `
                     '这看起来不像完整的 ComfyUI 文件夹。仍然安装到这里？[y/N]'
        if ($reply -notmatch '^(y|yes)$') {
            Die "Stopped. Pass -ComfyPath with your ComfyUI folder." '已停止。请用 -ComfyPath 指定 ComfyUI 文件夹。'
        }
    }
}
else {
    Say "Several ComfyUI folders were found:" '找到多个 ComfyUI 文件夹：'
    for ($i = 0; $i -lt $all.Count; $i++) {
        $label = Split-Path $all[$i] -Parent
        if ($i -ge $sure.Count) { $label = "$label (?)" }
        Write-Host ("  {0}) {1}" -f ($i + 1), $label)
    }
    $choice = Ask "Which one? [1]" '选择哪一个？[1]'
    $index = 1
    if ($choice -match '^\d+$') { $index = [int]$choice }
    if ($index -lt 1 -or $index -gt $all.Count) { $index = 1 }
    $target = $all[$index - 1]
}

Say ("ComfyUI: " + (Split-Path $target -Parent)) ('ComfyUI 位置：' + (Split-Path $target -Parent))

# ------------------------------------------------------------------ the files

$dest = Join-Path $target $NodeDirName
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("merak-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    Say "Downloading the node..." '正在下载节点……'
    $zip = Join-Path $work "node.zip"
    try {
        Invoke-WebRequest -Uri "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" -OutFile $zip -UseBasicParsing
    }
    catch {
        Die "Download failed - check your internet connection and try again." '下载失败 —— 请检查网络连接后重试。'
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $work -Force

    $src = Join-Path $work "$NodeDirName-$Branch"
    if (-not (Test-Path -LiteralPath (Join-Path $src "merak_nodes.py"))) {
        $src = (Get-ChildItem -LiteralPath $work -Directory |
                Where-Object { Test-Path (Join-Path $_.FullName "merak_nodes.py") } |
                Select-Object -First 1).FullName
    }
    if (-not $src -or -not (Test-Path -LiteralPath (Join-Path $src "merak_nodes.py"))) {
        Die "The download looks incomplete." '下载的文件不完整。'
    }

    if (Test-Path -LiteralPath $dest) {
        $backup = "$dest.previous"
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
        Move-Item -LiteralPath $dest -Destination $backup
        Say "Replacing the previous version (kept as $NodeDirName.previous)." `
            "已替换旧版本（旧版本保留为 $NodeDirName.previous）。"
    }
    Move-Item -LiteralPath $src -Destination $dest
    if (-not (Test-Path -LiteralPath (Join-Path $dest "merak_nodes.py"))) {
        Die "Install failed." '安装失败。'
    }
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
                      '请粘贴你的 merak API key（在 https://merakcompute.ai 获取）：'
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
Say "Done. Restart ComfyUI, double-click the canvas and search for Merak." `
    '完成。请重启 ComfyUI，然后双击画布并搜索 Merak。'
Say "You should see: Merak Generate Video, Merak Fetch Video (by id)." `
    '你应该能看到：Merak Generate Video、Merak Fetch Video (by id)。'
Say "" ""
