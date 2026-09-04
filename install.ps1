# Merak for ComfyUI installer for Windows.
#
#   irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1 | iex

param(
    [string]$ApiKey = "",
    [string]$ComfyPath = "",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "This installer requires Windows PowerShell 5 or newer."
}

$Repo = "snarkify/merak-comfyui-node"
$Branch = "main"
$NodeName = "merak-comfyui-node"
$KeyDir = [IO.Path]::Combine($HOME, ".merak")
$KeyFile = [IO.Path]::Combine($KeyDir, "api_key")
$Candidates = New-Object System.Collections.ArrayList

function Ask([string]$Prompt) {
    if ($Yes -or -not [Environment]::UserInteractive) { return $null }
    return Read-Host $Prompt
}

function Add-Candidate([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $Path = $Path.Trim().TrimEnd('\', '/')
    if ((Split-Path $Path -Leaf) -eq "custom_nodes") {
        $root = Split-Path $Path -Parent
    }
    else {
        $root = $Path
    }

    $customNodes = [IO.Path]::Combine($root, "custom_nodes")
    if (-not (Test-Path -LiteralPath $customNodes -PathType Container)) { return }
    $looksLikeComfy = (Test-Path -LiteralPath ([IO.Path]::Combine($root, "main.py"))) -or
                      (Test-Path -LiteralPath ([IO.Path]::Combine($root, "comfyui_version.py"))) -or
                      (Test-Path -LiteralPath ([IO.Path]::Combine($root, "comfy")) -PathType Container)
    if (-not $looksLikeComfy) { return }

    $fullPath = (Resolve-Path -LiteralPath $root).Path
    if ($Candidates -notcontains $fullPath) { [void]$Candidates.Add($fullPath) }
}

$explicitPath = $PSBoundParameters.ContainsKey("ComfyPath")
if ($explicitPath -and [string]::IsNullOrWhiteSpace($ComfyPath)) {
    throw "-ComfyPath needs a value."
}

if ($explicitPath) {
    Add-Candidate $ComfyPath
    if ($Candidates.Count -eq 0) { throw "That does not look like a ComfyUI folder: $ComfyPath" }
}
elseif ($env:COMFYUI_PATH) {
    Add-Candidate $env:COMFYUI_PATH
    if ($Candidates.Count -eq 0) { throw "COMFYUI_PATH is not a ComfyUI folder: $env:COMFYUI_PATH" }
}
else {
    $commonPaths = @(
        [IO.Path]::Combine($HOME, "ComfyUI"),
        [IO.Path]::Combine($HOME, "Documents", "ComfyUI"),
        [IO.Path]::Combine($HOME, "Desktop", "ComfyUI"),
        [IO.Path]::Combine($HOME, "Downloads", "ComfyUI"),
        [IO.Path]::Combine($HOME, "Downloads", "ComfyUI_windows_portable", "ComfyUI"),
        "C:\ComfyUI",
        "C:\ComfyUI_windows_portable\ComfyUI"
    )
    $documents = [Environment]::GetFolderPath("MyDocuments")
    $desktop = [Environment]::GetFolderPath("Desktop")
    if ($documents) { $commonPaths += [IO.Path]::Combine($documents, "ComfyUI") }
    if ($desktop) {
        $commonPaths += [IO.Path]::Combine($desktop, "ComfyUI")
        $commonPaths += [IO.Path]::Combine($desktop, "ComfyUI_windows_portable", "ComfyUI")
    }
    foreach ($path in $commonPaths) { Add-Candidate $path }

    $installParents = @([IO.Path]::Combine($HOME, "ComfyUI-Installs"))
    if ($env:LOCALAPPDATA) {
        $installParents += [IO.Path]::Combine($env:LOCALAPPDATA, "Comfy-Desktop", "ComfyUI-Installs")
    }
    foreach ($parent in $installParents) {
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        foreach ($child in Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue) {
            Add-Candidate $child.FullName
            Add-Candidate ([IO.Path]::Combine($child.FullName, "ComfyUI"))
        }
    }
}

if ($Candidates.Count -eq 0) {
    $answer = Ask "Full path to your ComfyUI folder"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        throw "ComfyUI was not found. Run again with -ComfyPath C:\path\to\ComfyUI."
    }
    Add-Candidate $answer
    if ($Candidates.Count -eq 0) { throw "That does not look like a ComfyUI folder: $answer" }
}

if ($Candidates.Count -gt 1) {
    Write-Host "Several ComfyUI folders were found:"
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $Candidates[$i])
    }
    $choice = Ask "Which one? [1]"
    if ($null -eq $choice) { throw "Run again with -ComfyPath to choose a ComfyUI folder." }
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
    if ($choice -notmatch '^\d+$') { throw "Not a number: $choice" }
    $index = [int]$choice
    if ($index -lt 1 -or $index -gt $Candidates.Count) { throw "Invalid choice: $choice" }
    $Target = $Candidates[$index - 1]
}
else {
    $Target = $Candidates[0]
}

$CustomNodes = [IO.Path]::Combine($Target, "custom_nodes")
$Dest = [IO.Path]::Combine($CustomNodes, $NodeName)
$Backup = "$Dest.previous"
$Work = [IO.Path]::Combine([IO.Path]::GetTempPath(), "merak-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Work | Out-Null

Write-Host "Installing Merak into $Target"
try {
    $zip = [IO.Path]::Combine($Work, "node.zip")
    if ($env:MERAK_ARCHIVE) {
        Copy-Item -LiteralPath $env:MERAK_ARCHIVE -Destination $zip
    }
    else {
        Invoke-WebRequest -Uri "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" -OutFile $zip -UseBasicParsing
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $Work

    $Source = [IO.Path]::Combine($Work, "$NodeName-$Branch")
    if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($Source, "merak_nodes.py")))) {
        throw "The downloaded archive is incomplete."
    }

    $madeBackup = $false
    if (Test-Path -LiteralPath $Dest) {
        if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
        Move-Item -LiteralPath $Dest -Destination $Backup
        $madeBackup = $true
    }
    try {
        Move-Item -LiteralPath $Source -Destination $Dest
    }
    catch {
        if ($madeBackup -and -not (Test-Path -LiteralPath $Dest)) {
            Move-Item -LiteralPath $Backup -Destination $Dest
        }
        throw
    }
}
finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Installed to $Dest"

$existingKey = ""
if (Test-Path -LiteralPath $KeyFile) {
    $existingKey = "" + (Get-Content -LiteralPath $KeyFile -Raw -ErrorAction SilentlyContinue)
}
if (-not $ApiKey -and -not $existingKey.Trim()) {
    $ApiKey = Ask "Paste your merak API key"
}
$ApiKey = "" + $ApiKey
$ApiKey = $ApiKey -replace '\s', ''
if ($ApiKey) {
    New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null
    [IO.File]::WriteAllText($KeyFile, $ApiKey + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Key saved to $KeyFile"
}
elseif ($existingKey.Trim()) {
    Write-Host "Keeping the existing key in $KeyFile"
}
else {
    Write-Host "No key saved. Put it in $KeyFile before using the node."
}

Write-Host "Done. Restart ComfyUI and search for Merak."
