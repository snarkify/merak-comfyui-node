$ErrorActionPreference = "Stop"

$Repo = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
$Installer = Join-Path $Repo "install.ps1"
$HostExe = (Get-Process -Id $PID).Path
$Work = Join-Path ([IO.Path]::GetTempPath()) ("merak-test-" + [Guid]::NewGuid().ToString("N"))
$Archive = Join-Path $Work "node.zip"
$Checks = 0
$Failures = 0

function Comfy([string]$Path) {
    New-Item -ItemType Directory -Path (Join-Path $Path "custom_nodes") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path "main.py") -Value "" -NoNewline
}

function Run-Installer([string]$HomePath, [string[]]$Arguments) {
    $saved = @{
        HOME = $env:HOME
        USERPROFILE = $env:USERPROFILE
        HOMEDRIVE = $env:HOMEDRIVE
        HOMEPATH = $env:HOMEPATH
        LOCALAPPDATA = $env:LOCALAPPDATA
        COMFYUI_PATH = $env:COMFYUI_PATH
        MERAK_ARCHIVE = $env:MERAK_ARCHIVE
    }
    try {
        $savedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $env:HOME = $HomePath
        $env:USERPROFILE = $HomePath
        if ($HomePath -match '^([A-Za-z]:)(.*)$') {
            $env:HOMEDRIVE = $Matches[1]
            $env:HOMEPATH = $Matches[2]
        }
        $env:LOCALAPPDATA = Join-Path $HomePath "AppData\Local"
        $env:COMFYUI_PATH = ""
        $env:MERAK_ARCHIVE = $Archive
        $flags = @("-NoProfile")
        if ($IsWindows -or $PSVersionTable.PSEdition -eq "Desktop") {
            $flags += @("-ExecutionPolicy", "Bypass")
        }
        $flags += @("-File", $Installer)
        $output = (& $HostExe @flags @Arguments 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ Code = $exitCode; Output = $output }
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                Remove-Item "env:$name" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item "env:$name" $saved[$name]
            }
        }
    }
}

function Check([string]$Name, [bool]$Passed) {
    $script:Checks++
    if ($Passed) {
        Write-Host "ok - $Name"
    }
    else {
        $script:Failures++
        Write-Host "FAIL - $Name"
    }
}

try {
    $source = Join-Path $Work "source\merak-comfyui-node-main"
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    Copy-Item (Join-Path $Repo "merak_nodes.py") $source
    Copy-Item (Join-Path $Repo "__init__.py") $source
    Compress-Archive -Path $source -DestinationPath $Archive

    $testHome = Join-Path $Work "explicit-home"
    $root = Join-Path $Work "explicit\ComfyUI"
    New-Item -ItemType Directory -Path $testHome -Force | Out-Null
    Comfy $root
    $result = Run-Installer $testHome @("-ComfyPath", $root, "-ApiKey", "test-key", "-Yes")
    $installed = Test-Path (Join-Path $root "custom_nodes\merak-comfyui-node\merak_nodes.py")
    $keyFile = Join-Path $testHome ".merak\api_key"
    $keySaved = (Test-Path $keyFile) -and ((Get-Content $keyFile -Raw).Trim() -eq "test-key")
    Check "explicit path installs the node and key" ($result.Code -eq 0 -and $installed -and $keySaved)

    $testHome = Join-Path $Work "multiple-home"
    Comfy (Join-Path $testHome "ComfyUI")
    Comfy (Join-Path $testHome "Documents\ComfyUI")
    $result = Run-Installer $testHome @("-Yes")
    $nothingInstalled = -not (Get-ChildItem $testHome -Recurse -Directory -Filter "merak-comfyui-node" -ErrorAction SilentlyContinue)
    Check "multiple installs require an explicit choice" ($result.Code -ne 0 -and $nothingInstalled)

    $testHome = Join-Path $Work "invalid-home"
    New-Item -ItemType Directory -Path $testHome -Force | Out-Null
    $result = Run-Installer $testHome @("-ComfyPath", (Join-Path $testHome "missing"), "-Yes")
    Check "invalid path is rejected" ($result.Code -ne 0)
}
finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Failures -gt 0) {
    Write-Host "$Failures of $Checks checks failed"
    exit 1
}
Write-Host "$Checks checks passed"
