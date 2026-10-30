#requires -Version 5.0
<#
WinRepair installer/updater for Windows 10/11 and Server 2016+.
Downloads the GitHub branch archive using curl.exe where available.
Falls back to Invoke-WebRequest on older Windows 10 builds.
Shows one plan, asks once, stages .new files, then replaces using same-volume
File.Replace / File.Move. Does not delete unrelated files or create log files.

Repository points to the planned GitHub project and works after publication.
#>
[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path $env:ProgramFiles 'WinRepair'),
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'avmaksimov/WinRepair',
    [ValidatePattern('^[A-Za-z0-9_./-]+$')]
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$tempDir = $null

function Ask-Confirmation {
    while ($true) {
        $answer = (Read-Host 'Apply all changes? [Y/N]').Trim().ToUpperInvariant()
        if (@('Y','YES') -contains $answer) { return $true }
        if (@('N','NO','') -contains $answer) { return $false }
        Write-Host 'Please enter Y or N.' -ForegroundColor Yellow
    }
}

function Download-RepositoryArchive {
    param([string]$Url, [string]$Destination)
    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        Write-Host 'Downloading archive with curl.exe...' -ForegroundColor Cyan
        & $curl.Source --fail --location --silent --show-error --retry 2 --output $Destination $Url
        if ($LASTEXITCODE -ne 0) {
            throw ('curl.exe exited with code ' + $LASTEXITCODE + '. Verify repository access.')
        }
    } else {
        Write-Host 'curl.exe is unavailable; falling back to Invoke-WebRequest.' -ForegroundColor Yellow
        # Required on some early Windows 10 builds where the default TLS is older.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
    }
    $downloaded = Get-Item -LiteralPath $Destination -ErrorAction Stop
    if ($downloaded.Length -lt 100) { throw 'Archive is empty or unexpectedly small.' }
}

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ([version]$os.Version -lt [version]'10.0') {
        throw 'Supported systems: Windows 10/11 and Windows Server 2016 or later.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run Windows PowerShell as administrator and retry.'
    }
    if ($Branch.Contains('..') -or $Branch.StartsWith('/') -or $Branch.EndsWith('/')) {
        throw 'Invalid branch name.'
    }

    $InstallPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($InstallPath))
    $zipUrl = 'https://github.com/{0}/archive/refs/heads/{1}.zip' -f $Repository, $Branch
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('WinRepair-' + [Guid]::NewGuid().ToString('N'))
    $unpacked = Join-Path $tempDir 'unpacked'
    New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
    $archive = Join-Path $tempDir 'source.zip'
    Write-Host '================================================' -ForegroundColor Cyan
    Write-Host 'WinRepair - Install / Update' -ForegroundColor Cyan
    Write-Host ('Repository: ' + $Repository + ' (' + $Branch + ')')
    Write-Host ('Install path: ' + $InstallPath)
    Write-Host '================================================' -ForegroundColor Cyan
    Download-RepositoryArchive -Url $zipUrl -Destination $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $unpacked -Force -ErrorAction Stop

    $folders = @(Get-ChildItem -LiteralPath $unpacked -Directory -ErrorAction Stop)
    if ($folders.Count -ne 1) { throw 'Unexpected GitHub ZIP archive layout.' }
    $sourceRoot = $folders[0].FullName
    foreach ($required in @('WinRepair.cmd','WinRepair.ps1','install.ps1','README.md','README.ru.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required) -PathType Leaf)) {
            throw ('Required file missing from archive: ' + $required)
        }
    }

    $allFiles = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -ErrorAction Stop | Sort-Object FullName)
    $tasks = @()
    foreach ($source in $allFiles) {
        $relative = $source.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $target = Join-Path $InstallPath $relative
        $state = 'NEW'
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $srcHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            $state = if ($srcHash -eq $dstHash) { 'UNCHANGED' } else { 'UPDATE' }
        }
        $tasks += [pscustomobject]@{ Source=$source.FullName; Relative=$relative; Target=$target; State=$state }
    }
    Write-Host "`nRepository files:" -ForegroundColor Cyan
    foreach ($task in $tasks) { Write-Host ('  {0,-9} {1}' -f $task.State, $task.Relative) }
    $changes = @($tasks | Where-Object { $_.State -ne 'UNCHANGED' })
    Write-Host ("`nNew: {0}; Updated: {1}; Unchanged: {2}" -f @($tasks | Where-Object { $_.State -eq 'NEW' }).Count, @($tasks | Where-Object { $_.State -eq 'UPDATE' }).Count, @($tasks | Where-Object { $_.State -eq 'UNCHANGED' }).Count)
    if ($changes.Count -eq 0) {
        Write-Host 'All files are up to date. No changes needed.' -ForegroundColor Green
        exit 0
    }

    Write-Host "`nFiles absent from the repository are not deleted from the destination."
    Write-Host 'If the update fails midway, some files may already have been replaced.' -ForegroundColor Yellow
    if (-not (Ask-Confirmation)) {
        Write-Host 'Canceled. No installed files were changed.' -ForegroundColor Yellow
        exit 0
    }

    # A batch of .new files is prepared *before* any working file is touched.
    # Refuse to overwrite an existing .new file: it might belong to the user.
    foreach ($task in $changes) {
        if (Test-Path -LiteralPath ($task.Target + '.new')) {
            throw ('An existing .new file was found: ' + $task.Target + '.new. Remove it manually before retrying.')
        }
    }
    $prepared = @()
    try {
        foreach ($task in $changes) {
            $parent = Split-Path -Path $task.Target -Parent
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            $newPath = $task.Target + '.new'
            [IO.File]::Copy($task.Source, $newPath, $false)
            $prepared += $newPath
        }
        # Updating the running installer last reduces the chance of replacing
        # an in-use script before other required files have been updated.
        $ordered = @($changes | Sort-Object @{ Expression={ if ($_.Relative -ieq 'install.ps1') { 1 } else { 0 } } }, Relative)
        $completed = 0
        foreach ($task in $ordered) {
            $newPath = $task.Target + '.new'
            if (Test-Path -LiteralPath $task.Target -PathType Leaf) {
                [IO.File]::Replace($newPath, $task.Target, $null)
            } else {
                [IO.File]::Move($newPath, $task.Target)
            }
            Write-Host ('  OK  ' + $task.Relative) -ForegroundColor Green
            $completed++
        }
        Write-Host ("`nCompleted. Files installed or updated: " + $completed + '.') -ForegroundColor Green
        Write-Host ('Run: ' + (Join-Path $InstallPath 'WinRepair.cmd')) -ForegroundColor Cyan
    } finally {
        # Only staged .new files created in this run are cleaned up.
        foreach ($newPath in $prepared) {
            if (Test-Path -LiteralPath $newPath -PathType Leaf) {
                Remove-Item -LiteralPath $newPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
} catch {
    Write-Host ('WinRepair installation error: ' + $_.Exception.Message) -ForegroundColor Red
    exit 2
} finally {
    if (($null -ne $tempDir) -and (Test-Path -LiteralPath $tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
