#requires -Version 2.0
<#
WinRepair: OS-aware Windows repair (Windows 7/Server 2008 R2 and newer).
- Windows client 8+: first try DISM with default source. Offer ISO/WIM/ESD on failure.
- Windows Server 2012+: ask for source immediately, but allow default source.
- Check the system volume before Windows repair (Repair-Volume or CHKDSK).
- Windows 7 / Server 2008 R2 and earlier: no unsupported RestoreHealth; run SFC.
- Run SFC even if DISM fails. Offer a safe in-place Windows Setup from selected media on failure.
- Ctrl+C cancels the script.
- No WSUS policy changes, component cleanup or cache reset; reboot only with consent.
- Compatible with Windows PowerShell 2.0 (shipped with Windows 7).
#>
# Internal switches preserve the launch mode when relaunching via UAC.
param([switch]$PauseAtExit, [switch]$NoPauseAtExit)

# Only an Explorer-initiated, dedicated PowerShell process waits for a key.
# -File alone is insufficient: terminals can use powershell.exe -File too.
function Test-ExplorerLaunch {
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        $current = Get-WmiObject -Class Win32_Process -Filter ("ProcessId = {0}" -f $PID) -ErrorAction Stop
        if ($null -eq $current) { return $false }
        $commandLine = [string]$current.CommandLine
        # -NoExit indicates a console that the caller explicitly keeps open.
        if ($commandLine -match '(?i)(?:^|\s)-noexit\b') { return $false }
        if ($commandLine -notmatch '(?i)(?:^|\s)-(?:file|command)\b') { return $false }
        $parent = Get-WmiObject -Class Win32_Process -Filter ("ProcessId = {0}" -f $current.ParentProcessId) -ErrorAction Stop
        if ($null -eq $parent) { return $false }
        # An already elevated Explorer launch may be parented by UAC AppInfo
        # (svchost.exe) instead of explorer.exe.
        $parentName = ([string]$parent.Name).ToLowerInvariant()
        return (@('explorer.exe', 'svchost.exe', 'consent.exe') -contains $parentName)
    } catch { return $false }
}
function Wait-ForExitKey {
    if (-not $script:PauseAtExit) { return }
    Write-Host ''
    Write-Host 'Нажмите любую клавишу для закрытия окна...'
    try {
        [void][Console]::ReadKey($true)
    } catch {
        # ReadKey is not available for every console host; Read-Host is a
        # compatible fallback on Windows PowerShell 2.0 and later.
        try { [void](Read-Host 'Нажмите Enter для выхода') } catch { }
    }
}
if ($NoPauseAtExit) {
    $script:PauseAtExit = $false
} elseif ($PauseAtExit) {
    $script:PauseAtExit = $true
} else {
    $script:PauseAtExit = Test-ExplorerLaunch
}
$script:ElevationStarted = $false


$script:DiskResult = $null
$script:SfcResult = $null
$script:VolumeStatus = 'Не проверялся'
$script:VolumeNeedsAttention = $false
$script:VolumeScheduled = $false
$script:RestartRequested = $false
$script:RestartInitiated = $false
$script:HadError = $false
$script:TranscriptOn = $false
$script:LogPath = $null
$script:SelectedRepairImage = $null
$script:SelectedRepairDetails = $null
$script:SelectedRepairIndex = 0
$script:SetupLaunched = $false
$script:ProgramDirectory = Join-Path $env:SystemRoot 'System32'
if (($env:PROCESSOR_ARCHITEW6432 -ne $null) -and ($env:PROCESSOR_ARCHITEW6432 -ne '')) {
    # Running 32-bit PowerShell on a 64-bit OS: use native system binaries.
    $script:ProgramDirectory = Join-Path $env:SystemRoot 'Sysnative'
}
$script:DismExe = Join-Path $script:ProgramDirectory 'dism.exe'
$script:SfcExe = Join-Path $script:ProgramDirectory 'sfc.exe'
$script:ChkdskExe = Join-Path $script:ProgramDirectory 'chkdsk.exe'
$script:ChkntfsExe = Join-Path $script:ProgramDirectory 'chkntfs.exe'

function Ask-YesNo {
    param([string]$Question, [bool]$DefaultYes)
    $defaultText = if ($DefaultYes) { 'Y' } else { 'N' }
    while ($true) {
        $answer = (Read-Host ("{0} [Y/N, Enter={1}]" -f $Question, $defaultText)).Trim().ToUpperInvariant()
        if ($answer.Length -eq 0) { return $DefaultYes }
        if (@('Д', 'ДА', 'Y', 'YES') -contains $answer) { return $true }
        if (@('Н', 'НЕТ', 'N', 'NO') -contains $answer) { return $false }
        Write-Host 'Введите Y или N.' -ForegroundColor Yellow
    }
}

function Format-ExitCode {
    param([int]$Code)
    return ('{0} (0x{1:X8})' -f $Code, ([BitConverter]::ToUInt32([BitConverter]::GetBytes($Code), 0)))
}

function Find-ImageAtPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $value = $Path.Trim().Trim('"')
    if ($value -match '^[A-Za-z]:$') { $value = $value + '\' }
    if ($value -match '^[A-Za-z]$') { $value = $value + ':\' }
    if (-not (Test-Path -LiteralPath $value)) { return $null }
    $item = Get-Item -LiteralPath $value -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        if ($item.Extension -match '^\.(wim|esd)$') { return $item.FullName }
        return $null
    }
    foreach ($relative in @('sources\install.wim', 'sources\install.esd', 'install.wim', 'install.esd')) {
        $candidate = Join-Path $item.FullName $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Find-ImagesOnDrives {
    # Search only conventional ISO roots, not a costly recursive scan of disks.
    $found = @()
    $checked = @()
    try {
        $drives = @(Get-WmiObject -Class Win32_LogicalDisk -ErrorAction Stop |
            Where-Object { @('2','3','4','5') -contains ([string]$_.DriveType) } |
            Sort-Object DeviceID)
    } catch {
        $drives = @()
        foreach ($disk in [IO.DriveInfo]::GetDrives()) {
            if ($disk.DriveType -ne [IO.DriveType]::Unknown) {
                $drives += (New-Object PSObject -Property @{ DeviceID = $disk.Name.TrimEnd('\'); DriveType = [string][int]$disk.DriveType })
            }
        }
    }
    foreach ($drive in $drives) {
        $root = [string]$drive.DeviceID
        if ($root -notmatch '^[A-Za-z]:$') { continue }
        $checked += $root
        $file = $null
        try { $file = Find-ImageAtPath $root } catch { }
        if (($file -ne $null) -and (-not ($found -contains $file))) { $found += $file }
    }
    Write-Host ('Проверены диски: ' + $(if ($checked.Count -gt 0) { $checked -join ', ' } else { 'не удалось получить список' }))
    Write-Host 'Проверялись только sources\install.wim, sources\install.esd (и файлы в корне), без поиска по всем папкам.'
    return $found
}

function Choose-Image {
    param([switch]$AskForDrive)
    # After failed DISM without ISO, ask for the mounted drive directly.
    # For other scenarios, retain the existing automatic image discovery.
    if (-not $AskForDrive) {
        Write-Host ''
        Write-Host 'Поиск установочного образа на доступных дисках...' -ForegroundColor Cyan
        $found = @(Find-ImagesOnDrives)
        if ($found.Count -eq 1) {
            Write-Host ('Найден один образ: ' + $found[0]) -ForegroundColor Green
            Write-Host 'Используется найденный образ. Если он не подходит, можно выбрать другой при следующей попытке.'
            return [string]$found[0]
        }
        if ($found.Count -gt 1) {
            Write-Host 'Найдено несколько образов:' -ForegroundColor Cyan
            for ($i = 0; $i -lt $found.Count; $i++) {
                Write-Host (' {0}. {1}' -f ($i + 1), $found[$i])
            }
            while ($true) {
                $answer = (Read-Host 'Номер образа (Enter — указать другую букву)').Trim()
                if ($answer -eq '') { break }
                $selected = 0
                if ([int]::TryParse($answer, [ref]$selected) -and $selected -gt 0 -and $selected -le $found.Count) {
                    return [string]$found[$selected - 1]
                }
                Write-Host 'Неверный номер.' -ForegroundColor Yellow
            }
        } else {
            Write-Host 'Смонтированный установочный образ автоматически не найден.' -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host 'Смонтируйте установочный ISO Windows и введите букву его диска без двоеточия (например, E).' -ForegroundColor Cyan
    Write-Host 'При необходимости допускается полный путь к install.wim / install.esd.'
    Write-Host 'Enter — пропустить восстановление из ISO и перейти к SFC.'
    while ($true) {
        $raw = (Read-Host 'Буква диска').Trim()
        if ($raw.Length -eq 0) { return $null }
        try { $file = Find-ImageAtPath $raw } catch { $file = $null }
        if ($file -ne $null) {
            Write-Host ('Найден образ: ' + $file) -ForegroundColor Green
            return $file
        }
        Write-Host 'Не найден sources\install.wim или sources\install.esd. Проверьте букву диска.' -ForegroundColor Yellow
    }
}

function Get-OsImageProfile {
    param($OperatingSystem, [string]$Edition, [bool]$IsServer)
    # Win32_Processor.AddressWidth is the operating system bitness, even with 32-bit PowerShell.
    $cpu = Get-WmiObject Win32_Processor | Select-Object -First 1
    $arch = ''
    if ($cpu -ne $null) {
        if ([int]$cpu.AddressWidth -eq 32) { $arch = 'x86' }
        elseif ([int]$cpu.Architecture -eq 12) { $arch = 'arm64' }
        elseif ([int]$cpu.AddressWidth -eq 64) { $arch = 'x64' }
    }
    $installation = if ($IsServer) { 'Server' } else { 'Client' }
    if ($IsServer) {
        try {
            $installation = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).InstallationType
        } catch { $installation = '' }
    }
    # Get-UICulture is advisory for the default image language, not a guarantee of OS integrity.
    $lang = ''
    try { $lang = [string](Get-UICulture).Name } catch { }
    $osFamily = ''
    $name = [string]$OperatingSystem.Caption
    $familyMatch = [regex]::Match($name, '(?i)Windows Server\s+\d{4}(?:\s+R2)?|Windows\s+(?:11|10|8\.1|8|7)')
    if ($familyMatch.Success) { $osFamily = $familyMatch.Value }
    return (New-Object PSObject -Property @{
        Edition = $Edition; Architecture = $arch; Installation = $installation
        Language = $lang; Version = [string]$OperatingSystem.Version; Family = $osFamily
    })
}

function Get-ImageDetails {
    param([string]$ImagePath, [int]$ImageIndex)
    $raw = @(& $script:DismExe /English /Get-WimInfo ("/WimFile:{0}" -f $ImagePath) ("/Index:{0}" -f $ImageIndex) 2>&1)
    if ([int]$LASTEXITCODE -ne 0) { return $null }
    $output = [string]::Join("`n", [string[]]$raw)
    # DISM prints its OWN "Version: ..." before the image details. Parse only
    # the "Details for image" section, never the executable banner.
    $detailsHeading = [regex]::Match($output, '(?im)^\s*Details\s+for\s+image\s*:\s*[^\r\n]*')
    if (-not $detailsHeading.Success) {
        Write-Host 'Не удалось найти раздел метаданных образа в выводе DISM.' -ForegroundColor Yellow
        return $null
    }
    $body = $output.Substring($detailsHeading.Index + $detailsHeading.Length)
    $result = New-Object PSObject -Property @{
        Name = ''; Edition = ''; Architecture = ''; Installation = ''; Language = ''; Version = ''; ServicePackBuild = ''
    }
    foreach ($name in @('Name', 'Edition', 'Architecture', 'Installation', 'Version')) {

        $match = [regex]::Match($body, ('(?im)^\s*{0}\s*:\s*(.*?)\s*$' -f $name))
        if ($match.Success) { $result.$name = $match.Groups[1].Value.Trim() }
    }
    $servicePackBuild = [regex]::Match($body, '(?im)^\s*ServicePack Build\s*:\s*(\d+)\s*$')
    if ($servicePackBuild.Success) { $result.ServicePackBuild = $servicePackBuild.Groups[1].Value }
    # Prefer the language explicitly marked as Default. A single-language image is unambiguous too.
    $languageHeading = [regex]::Match($body, '(?im)^\s*Languages\s*:\s*([^\r\n]*)')
    if ($languageHeading.Success) {
        $rest = $body.Substring($languageHeading.Index + $languageHeading.Length)
        $nextSection = [regex]::Match($rest, '(?m)^\s*[A-Za-z][A-Za-z ]{2,}\s*:\s*')
        if ($nextSection.Success) { $rest = $rest.Substring(0, $nextSection.Index) }
        $langValues = @()
        foreach ($line in ($languageHeading.Groups[1].Value + "`n" + $rest).Split([char[]]@("`r", "`n"), [StringSplitOptions]::RemoveEmptyEntries)) {
            $match = [regex]::Match($line, '(?i)\b([a-z]{2,3}-[a-z0-9-]+)\b')
            if ($match.Success) {
                $langValues += (New-Object PSObject -Property @{ Name = $match.Groups[1].Value; Default = ($line -match '(?i)\(Default\)') })
            }
        }
        $default = @($langValues | Where-Object { $_.Default })
        if ($default.Count -eq 1) { $result.Language = $default[0].Name }
        elseif ($langValues.Count -eq 1) { $result.Language = $langValues[0].Name }
    }
    return $result
}

function Choose-ImageIndex {
    param([string]$ImagePath, [string]$OsCaption, $OsProfile, [bool]$IsServer)
    Write-Host ''
    Write-Host ('Редакции внутри: ' + $ImagePath) -ForegroundColor Cyan

    $rawLines = @(& $script:DismExe /English /Get-WimInfo ("/WimFile:{0}" -f $ImagePath) 2>&1)
    $code = [int]$LASTEXITCODE
    if ($code -ne 0) {
        foreach ($line in $rawLines) { Write-Host ([string]$line) }
        Write-Host ('Не удалось прочитать редакции: ' + (Format-ExitCode $code)) -ForegroundColor Red
        return $null
    }
    $images = @()
    $currentIndex = 0
    foreach ($line in $rawLines) {
        $value = [string]$line
        if ($value -match '^\s*Index\s*:\s*(\d+)\s*$') {
            $currentIndex = [int]$Matches[1]
        } elseif (($currentIndex -gt 0) -and ($value -match '^\s*Name\s*:\s*(.+?)\s*$')) {
            $images += (New-Object PSObject -Property @{ Index = $currentIndex; Name = $Matches[1] })
            $currentIndex = 0
        }
    }
    if ($images.Count -eq 0) {
        Write-Host 'Не удалось прочитать список индексов DISM. Выбор отменён.' -ForegroundColor Yellow
        foreach ($line in $rawLines) { Write-Host ([string]$line) }
        return $null
    }

    $targetName = ($OsCaption -replace '^\s*(Microsoft|Майкрософт)\s+', '').Trim()
    $nameMatches = @($images | Where-Object { $_.Name.Trim() -ieq $targetName })
    $suggested = 0
    if (($nameMatches.Count -eq 1) -and (-not $IsServer)) { $suggested = [int]$nameMatches[0].Index }

    Write-Host ''
    foreach ($image in $images) {
        $mark = if ([int]$image.Index -eq $suggested) { '  <-- название совпадает' } else { '' }
        Write-Host (' {0,2} — {1}{2}' -f $image.Index, $image.Name, $mark)
    }
    Write-Host ('Установленная ОС: {0}; EditionID: {1}' -f $OsCaption, $OsProfile.Edition)

    # Verify real WIM/ESD metadata (not only friendly name). Skip questions only if
    # Edition, Architecture, InstallationType and default language all match uniquely.
    Write-Host 'Проверка редакции, версии Windows, архитектуры, типа установки и языка...' -ForegroundColor Cyan
    $verified = @()
    $candidate = @()
    foreach ($image in $images) {
        $d = Get-ImageDetails -ImagePath $ImagePath -ImageIndex ([int]$image.Index)
        if ($null -eq $d) { continue }
        $sameEdition = ($OsProfile.Edition -ne '') -and ($d.Edition -ieq $OsProfile.Edition)
        $sameArch = ($OsProfile.Architecture -ne '') -and ($d.Architecture -ieq $OsProfile.Architecture)
        $sameInstallation = ($OsProfile.Installation -ne '') -and ($d.Installation -ieq $OsProfile.Installation)
        $sameLanguage = ($OsProfile.Language -ne '') -and ($d.Language -ieq $OsProfile.Language)
        $sameFamily = ($OsProfile.Family -ne '') -and ($image.Name.IndexOf([string]$OsProfile.Family, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        # Verify the build when available. Shared servicing baselines may differ, so
        # mismatches are not silently accepted but may still be manually confirmed.
        $sameVersion = ($d.Version -ne '') -and ($d.Version -ieq $OsProfile.Version)
        if ($sameEdition -and $sameArch -and $sameInstallation -and $sameFamily) {
            $candidate += [int]$image.Index
            if ($sameLanguage -and $sameVersion) { $verified += [int]$image.Index }
        }
    }
    if ($verified.Count -eq 1) {
        Write-Host ('Индекс {0} выбран автоматически: все проверенные параметры совпали.' -f $verified[0]) -ForegroundColor Green
        return [int]$verified[0]
    }
    # If language information is absent or different, do not assume 100% compatibility.
    # Offer Enter to accept a single well-supported candidate without hiding ambiguity.
    if ($candidate.Count -eq 1) { $suggested = [int]$candidate[0] }
    if ($verified.Count -gt 1) { $suggested = 0 }
    if ($candidate.Count -ne 1) { $suggested = 0 }

    if ($suggested -gt 0) {
        Write-Host ('Предложен индекс {0}; Enter — выбрать его.' -f $suggested) -ForegroundColor Cyan
        Write-Host 'Автовыбор пропущен: не все параметры образа удалось однозначно подтвердить.' -ForegroundColor Yellow
    } else {
        Write-Host 'Однозначного совпадения нет. Выберите индекс вручную.' -ForegroundColor Yellow
        if ($IsServer) { Write-Host 'На сервере особенно важно различать Server Core и Desktop Experience.' -ForegroundColor Yellow }
    }
    Write-Host 'Источник должен соответствовать установленной ОС; индекс не гарантирует наличие всех файлов для ремонта.' -ForegroundColor Yellow

    while ($true) {
        $question = if ($suggested -gt 0) { 'Индекс образа (Enter — предложенный)' } else { 'Индекс образа (Enter — отмена)' }
        $raw = (Read-Host $question).Trim()
        if ($raw.Length -eq 0) {
            if ($suggested -gt 0) { return $suggested }
            return $null
        }
        $index = 0
        if ([int]::TryParse($raw, [ref]$index)) {
            foreach ($image in $images) {
                if ([int]$image.Index -eq $index) { return $index }
            }
        }
        Write-Host 'Такого индекса в списке нет. Попробуйте ещё раз.' -ForegroundColor Yellow
    }
}

function Invoke-RepairExecutable {
    param([string]$Executable, [string]$Arguments)
    # System.Diagnostics.Process inherits the parent console, so DISM/SFC can
    # render their normal in-place progress. It also avoids the PowerShell bug
    # where Start-Process -NoNewWindow can report a bogus ExitCode of 0.
    $process = New-Object System.Diagnostics.Process
    try {
        $process.StartInfo.FileName = $Executable
        $process.StartInfo.Arguments = $Arguments
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $false
        if (-not $process.Start()) { throw ('Не удалось запустить ' + $Executable) }
        while (-not $process.WaitForExit(400)) { }
        $process.Refresh()
        return [int]$process.ExitCode
    } finally {
        if ($process -ne $null) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit(3000) | Out-Null
                }
            } catch { }
            $process.Dispose()
        }
    }
}

function Run-Dism {
    param([string]$ImagePath, [int]$ImageIndex)
    $argList = @('/Online', '/Cleanup-Image', '/RestoreHealth')
    if (-not [string]::IsNullOrEmpty($ImagePath)) {
        $kind = if ($ImagePath.ToLowerInvariant().EndsWith('.esd')) { 'ESD' } else { 'WIM' }
        # Quoted filename preserves spaces in the native DISM command line.
        $argList += ('/Source:{0}:"{1}":{2}' -f $kind, $ImagePath, $ImageIndex)
        # Always permit the Windows Update fallback: do not add /LimitAccess.
        # Actual Microsoft Update access still depends on local policies/network.
        Write-Host ("`nDISM с источником: {0}; индекс {1}" -f $ImagePath, $ImageIndex) -ForegroundColor Cyan
        Write-Host 'Резервный источник Windows Update разрешён (/LimitAccess не используется; доступ зависит от политик).'
    } else {
        Write-Host "`nDISM со стандартным источником восстановления." -ForegroundColor Cyan
    }

    # Do not catch cancellation and turn it into an ordinary DISM error.
    # In particular, Ctrl+C must not trigger the ISO prompt or SFC.
    $arguments = [string]::Join(' ', [string[]]$argList)
    $code = Invoke-RepairExecutable -Executable $script:DismExe -Arguments $arguments
    $color = if (($code -eq 0) -or ($code -eq 3010)) { 'Green' } else { 'Red' }
    Write-Host ('DISM: ' + (Format-ExitCode $code)) -ForegroundColor $color
    if ($code -eq -2146498283) {
        Write-Host 'Ошибка 0x800F0915: изучите ошибки CBS.log; совпадение редакции ISO не гарантирует наличия нужных компонентов.' -ForegroundColor Yellow
    }
    if (($code -ne 0) -and ($code -ne 3010) -and (-not [string]::IsNullOrEmpty($ImagePath))) {
        Write-Host 'Восстановление с ISO не удалось. Это не ошибка выбора индекса сама по себе:' -ForegroundColor Yellow
        Write-Host 'часть требуемых версий файлов может отсутствовать в образе; проверьте CBS.log.' -ForegroundColor Yellow
        if ($code -eq -2146498283) {
            Write-Host 'Источник восстановления не предоставил необходимые компоненты. Подробности в CBS.log и DISM.log.' -ForegroundColor Yellow
        } else {
            Write-Host 'Причину ошибки восстановления смотрите в CBS.log и DISM.log.' -ForegroundColor Yellow
        }
    }
    return $code
}


# Schedule an offline repair only with the user's explicit approval.
function Schedule-SystemVolumeCheck {
    param([string]$Drive)
    if (-not (Ask-YesNo ('Запланировать исправление {0} при следующей загрузке?' -f $Drive) $true)) {
        Write-Host 'Проверка при загрузке не запланирована.' -ForegroundColor Yellow
        return
    }
    $code = Invoke-RepairExecutable -Executable $script:ChkntfsExe -Arguments ('/c ' + $Drive)
    if ($code -eq 0) {
        $script:VolumeScheduled = $true
        $script:VolumeNeedsAttention = $true
        $script:VolumeStatus = 'ScheduledAtBoot'
        Write-Host 'Исправление запланировано при следующей загрузке.' -ForegroundColor Yellow
    } else {
        Write-Host ('Ошибка chkntfs: ' + (Format-ExitCode $code)) -ForegroundColor Red
    }
}

# Keep the native Repair-Volume progress, but put the actual drive letter
# in the command text shown by the PowerShell host (rather than $letter).
# Both interpolated values are strictly validated before building the block.
function Invoke-RepairVolume {
    param(
        [char]$DriveLetter,
        [ValidateSet('Scan', 'SpotFix', 'OfflineScanAndFix')][string]$Mode
    )
    $name = [string]$DriveLetter
    if ($name -notmatch '^[A-Za-z]$') { throw 'Некорректная буква тома.' }
    $command = ('Repair-Volume -DriveLetter {0} -{1} -ErrorAction Stop' -f $name, $Mode)
    if ($Mode -ne 'Scan') { $command += ' -Confirm:$false' }
    & ([scriptblock]::Create($command))
}

function Test-SystemVolume {
    param([version]$OsVersion)
    $drive = [string]$env:SystemDrive
    if ($drive -notmatch '^[A-Za-z]:$') {
        $script:VolumeStatus = 'UnknownSystemDrive'
        $script:VolumeNeedsAttention = $true
        Write-Host ('Не удалось определить системный том: ' + $drive) -ForegroundColor Red
        return
    }
    $letter = [char]$drive.Substring(0, 1)
    Write-Host ("`nПроверка файловой системы {0}..." -f $drive) -ForegroundColor Cyan
    if ($OsVersion -ge [version]'6.2') {
        $cmdlet = Get-Command Repair-Volume -ErrorAction SilentlyContinue
        if ($null -ne $cmdlet) {
            try {
                $scan = @(Invoke-RepairVolume -DriveLetter $letter -Mode Scan)
                if ($scan.Count -ne 1) { throw 'Repair-Volume вернул пустой или неоднозначный результат.' }
                $status = ([string]$scan[0]).Trim()
                $script:VolumeStatus = $status
                Write-Host ('Repair-Volume -Scan: ' + $status)
                if ($status -eq 'NoErrorsFound') {
                    Write-Host 'Файловая система исправна.' -ForegroundColor Green
                    return
                }
                if (@('SpotFixNeeded', 'OfflineScanAndFixNeeded', 'ScanNeeded') -contains $status) {
                    $script:VolumeNeedsAttention = $true
                    Write-Host ('Тому требуется исправление или дополнительная проверка: ' + $status) -ForegroundColor Yellow
                    $spot = ($status -eq 'SpotFixNeeded')
                    $mode = if ($spot) { 'SpotFix' } else { 'OfflineScanAndFix' }
                    if (Ask-YesNo ('Попробовать Repair-Volume -{0} для {1}?' -f $mode, $drive) $true) {
                        try {
                            if ($spot) {
                                $fix = @(Invoke-RepairVolume -DriveLetter $letter -Mode SpotFix)
                            } else {
                                $fix = @(Invoke-RepairVolume -DriveLetter $letter -Mode OfflineScanAndFix)
                            }
                            Write-Host ('Результат исправления: ' + ($fix -join ', '))
                            $verify = @(Invoke-RepairVolume -DriveLetter $letter -Mode Scan)
                            if (($verify.Count -eq 1) -and (([string]$verify[0]).Trim() -eq 'NoErrorsFound')) {
                                $script:VolumeNeedsAttention = $false
                                $script:VolumeStatus = 'Repaired'
                                Write-Host 'Повторная проверка: ошибок нет.' -ForegroundColor Green
                                return
                            }
                            Write-Host ('После исправления ещё требуется проверка: ' + ($verify -join ', ')) -ForegroundColor Yellow
                        } catch [System.Management.Automation.PipelineStoppedException] {
                            throw
                        } catch {
                            Write-Host ('Онлайн-исправление не завершено: ' + $_.Exception.Message) -ForegroundColor Yellow
                        }
                    }
                    Schedule-SystemVolumeCheck -Drive $drive
                    return
                }
                Write-Host 'Неизвестный статус Repair-Volume; перехожу к CHKDSK.' -ForegroundColor Yellow
            } catch [System.Management.Automation.PipelineStoppedException] {
                throw
            } catch {
                Write-Host ('Не удалось проверить том через Repair-Volume: ' + $_.Exception.Message) -ForegroundColor Yellow
                Write-Host 'Перехожу к CHKDSK без исправления.' -ForegroundColor Yellow
            }
        } else {
            Write-Host 'Repair-Volume недоступен, использую CHKDSK.' -ForegroundColor Yellow
        }
    } else {
        Write-Host 'Windows 7 / Server 2008 R2: CHKDSK без исправления.' -ForegroundColor Cyan
    }
    # Read-only fallback: neither /f nor /r is used automatically.
    $code = Invoke-RepairExecutable -Executable $script:ChkdskExe -Arguments $drive
    $script:VolumeStatus = ('CHKDSK ' + (Format-ExitCode $code))
    if ($code -eq 0) {
        Write-Host 'CHKDSK: ошибок не обнаружено.' -ForegroundColor Green
        return
    }
    $script:VolumeNeedsAttention = $true
    Write-Host ('CHKDSK: ' + (Format-ExitCode $code)) -ForegroundColor Yellow
    Write-Host 'Возможны ошибки файловой системы или невозможность проверки. Изучите вывод.'
    Schedule-SystemVolumeCheck -Drive $drive
}


# Only offer Setup from an installation source that was already explicitly
# selected for DISM. /Auto Upgrade preserves BOTH applications and data; if
# unsupported, Windows Setup must fail instead of switching to DataOnly/Clean.
function Offer-InPlaceWindowsSetup {
    param([string]$OsCaption, $OsProfile, [bool]$IsServer, [version]$OsVersion)

    if ($IsServer -or ($OsVersion -lt [version]'10.0')) {
        Write-Host 'Автоматический запуск Setup предлагается только для Windows 10/11; для других ОС используйте установщик вручную.' -ForegroundColor Yellow
        return
    }
    $image = [string]$script:SelectedRepairImage
    if ([string]::IsNullOrEmpty($image)) {
        Write-Host 'Установочный ISO не был выбран. Смонтируйте совместимый ISO и запустите setup.exe вручную.' -ForegroundColor Yellow
        return
    }
    # Require an image in the standard sources folder and setup.exe on the
    # very same media; a random .wim/.esd cannot safely identify its installer.
    $match = [regex]::Match($image, '(?i)^([A-Z]:)\\sources\\install\.(?:wim|esd)$')
    if (-not $match.Success) {
        Write-Host 'Источник WIM/ESD не находится в стандартной папке sources на установочном носителе.' -ForegroundColor Yellow
        Write-Host 'Запустите setup.exe вручную с подходящего ISO Windows.' -ForegroundColor Yellow
        return
    }
    $setup = Join-Path ($match.Groups[1].Value + '\') 'setup.exe'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
        Write-Host ('На носителе не найден установщик: ' + $setup) -ForegroundColor Yellow
        return
    }
    $index = [int]$script:SelectedRepairIndex
    if ($index -le 0) {
        Write-Host 'Индекс образа не выбран. Запуск Setup отменён.' -ForegroundColor Yellow
        return
    }
    # Re-read metadata for exactly the index being passed to setup.exe.
    # Do not rely on the earlier DISM choice if media content has changed.
    $details = Get-ImageDetails -ImagePath $image -ImageIndex $index
    if ($null -eq $details) {
        Write-Host 'Не удалось подтвердить метаданные установочного образа; запускайте Setup вручную.' -ForegroundColor Yellow
        return
    }
    if (($OsProfile.Edition -eq '') -or ($details.Edition -ieq '') -or
        ($details.Edition -ine $OsProfile.Edition)) {
        Write-Host ('Редакция ISO не подтверждена: установлена {0}, выбран индекс {1} ({2}).' -f $OsProfile.Edition, $script:SelectedRepairIndex, $details.Edition) -ForegroundColor Yellow
        Write-Host 'Автоматический запуск Setup отменён: сначала проверьте редакцию образа.' -ForegroundColor Yellow
        return
    }
    if (($OsProfile.Architecture -eq '') -or ($details.Architecture -eq '') -or
        ($details.Architecture -ine $OsProfile.Architecture) -or
        ($details.Installation -ine 'Client')) {
        Write-Host 'Архитектура или тип установки ISO не соответствует текущей Windows.' -ForegroundColor Yellow
        return
    }
    if (($OsProfile.Language -eq '') -or ($details.Language -eq '') -or
        ($details.Language -ine $OsProfile.Language)) {
        Write-Host ('Не совпадает или не определён язык: текущий {0}; ISO {1}.' -f $OsProfile.Language, $details.Language) -ForegroundColor Yellow
        Write-Host 'Для сохранения приложений язык установочного носителя должен соответствовать языку исходной установки Windows.' -ForegroundColor Yellow
        return
    }
    try {
        $installed = [version]$OsProfile.Version
        $target = [version]$details.Version
        if ($target -lt $installed) {
            Write-Host ('ISO содержит более раннюю версию Windows ({0} < {1}).' -f $target, $installed) -ForegroundColor Yellow
            Write-Host 'Автоматический запуск Setup отменён, чтобы избежать отката версии.' -ForegroundColor Yellow
            return
        }
    } catch {
        Write-Host 'Не удалось надёжно сравнить версии Windows и образа. Запускайте Setup вручную.' -ForegroundColor Yellow
        return
    }

    # Explicitly preserve apps and files. DynamicUpdate Disable avoids downloads
    # during Setup, /EULA Accept avoids the extra Windows 11 license dialog.
    # Explicitly specify the index already checked by DISM. No /Quiet or
    # compatibility bypass: the user must see Setup and its warnings.
    $args = ('/Auto Upgrade /ImageIndex {0} /DynamicUpdate Disable /EULA Accept' -f $index)
    Write-Host ''
    $targetVersion = [string]$details.Version
    if (($details.ServicePackBuild -ne '') -and ($details.ServicePackBuild -ne '0')) {
        $targetVersion += '.' + $details.ServicePackBuild
    }
    Write-Host '================== СРАВНЕНИЕ РЕДАКЦИЙ ==================' -ForegroundColor Cyan
    Write-Host 'Текущая Windows:' -ForegroundColor Cyan
    Write-Host ('  Название:       {0}' -f $OsCaption)
    Write-Host ('  Редакция:       {0}' -f $OsProfile.Edition)
    Write-Host ('  Версия:         {0}' -f $OsProfile.Version)
    Write-Host ('  Архитектура:    {0}' -f $OsProfile.Architecture)
    Write-Host ('  Язык:           {0}' -f $OsProfile.Language)
    Write-Host ('Образ ISO (индекс {0}):' -f $index) -ForegroundColor Cyan
    Write-Host ('  Название:       {0}' -f $details.Name)
    Write-Host ('  Редакция:       {0}' -f $details.Edition)
    Write-Host ('  Версия:         {0}' -f $targetVersion)
    Write-Host ('  Архитектура:    {0}' -f $details.Architecture)
    Write-Host ('  Язык:           {0}' -f $details.Language)
    Write-Host ('  Установщик:    {0}' -f $setup)
    Write-Host 'Совпадение редакции, архитектуры и языка подтверждено; версию ISO проверили.' -ForegroundColor Green
    Write-Host 'Внимательно проверьте обе редакции и индекс перед запуском.' -ForegroundColor Yellow
    Write-Host ''
    if (-not (Ask-YesNo ('Запустить установку Windows поверх с сохранением программ и данных ({0})?' -f $args) $true)) {
        Write-Host 'Запуск установки отменён пользователем.'
        return
    }
    try {
        # Windows Setup runs independently. The console remains open at script
        # exit only when the original launch was from Explorer.
        $process = Start-Process -FilePath $setup -ArgumentList $args -PassThru -ErrorAction Stop
        if ($null -eq $process) { throw 'Start-Process не вернул сведения о процессе.' }
        $script:SetupLaunched = $true
        Write-Host ('Windows Setup запущен (PID {0}). Следите за его окном и проверками совместимости.' -f $process.Id) -ForegroundColor Green
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $script:HadError = $true
        Write-Host ('Не удалось запустить Windows Setup: ' + $_.Exception.Message) -ForegroundColor Red
    }
}


function Try-RepairFromImage {
    param([string]$OsCaption, $OsProfile, [bool]$IsServer, [switch]$AskForDrive)
    $image = Choose-Image -AskForDrive:$AskForDrive
    if ($null -eq $image) { return $null }
    $index = Choose-ImageIndex -ImagePath $image -OsCaption $OsCaption -OsProfile $OsProfile -IsServer $IsServer
    if ($null -eq $index) { return $null }
    # The image name/edition may match while its servicing build differs.
    # Show the image version so the user can diagnose a missing repair payload.
    $details = Get-ImageDetails -ImagePath $image -ImageIndex $index
    # Keep the exact media and selected edition for an optional in-place Setup.
    # This is only a candidate; Windows Setup performs its own compatibility check.
    $script:SelectedRepairImage = [string]$image
    $script:SelectedRepairIndex = [int]$index
    $script:SelectedRepairDetails = $details
    if (($null -ne $details) -and (-not [string]::IsNullOrEmpty($details.Version))) {
        $displayVersion = [string]$details.Version
        if (($details.ServicePackBuild -ne '') -and ($details.ServicePackBuild -ne '0')) {
            $displayVersion += ('.' + $details.ServicePackBuild)
        }
        Write-Host ('Версия Windows: {0}; версия образа ISO: {1}' -f $OsProfile.Version, $displayVersion)
        if (($OsProfile.Version -ne '') -and ($details.Version -ine $OsProfile.Version)) {
            Write-Host 'Версии различаются: образ для обновления Windows может иметь более новую сборку.' -ForegroundColor Yellow
            Write-Host 'Для DISM /RestoreHealth важно наличие конкретных версий повреждённых компонентов.' -ForegroundColor Yellow
        }
    }
    return (Run-Dism -ImagePath $image -ImageIndex $index)
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Требуются права администратора. Запрашиваю повышение прав (UAC)...' -ForegroundColor Yellow
        try {
            $scriptFile = [string]$MyInvocation.MyCommand.Path
            if ([string]::IsNullOrEmpty($scriptFile) -or
                -not (Test-Path -LiteralPath $scriptFile -PathType Leaf)) {
                throw 'Save WinRepair.ps1 to a file before requesting elevation.'
            }
            # As in WinRE-Manager: mapped drives may disappear after elevation.
            # Use a UNC path if the current file is on a mapped network drive.
            if ($scriptFile -match '^[A-Za-z]:\\') {
                $driveLetter = $scriptFile.Substring(0, 2)
                $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $driveLetter) -ErrorAction SilentlyContinue
                if (($null -ne $disk) -and ([int]$disk.DriveType -eq 4) -and
                    (-not [string]::IsNullOrEmpty([string]$disk.ProviderName))) {
                    $scriptFile = ([string]$disk.ProviderName).TrimEnd('\') + $scriptFile.Substring(2)
                    Write-Host ('Сетевой диск: использую UNC-путь ' + $scriptFile)
                }
            }
            # Preserve original launch mode for the elevated process. In
            # particular, a terminal-origin UAC launch must NOT start pausing.
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptFile
            if ($script:PauseAtExit) {
                $arguments += ' -PauseAtExit'
            } else {
                $arguments += ' -NoPauseAtExit'
            }
            # Use a guaranteed local working directory (not a mapped network drive).
            Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
                -ArgumentList $arguments -Verb RunAs -WorkingDirectory $env:SystemRoot -ErrorAction Stop | Out-Null
            Write-Host 'PowerShell с правами администратора запущен. Продолжайте в новом окне.'
            $script:ElevationStarted = $true
            return
        } catch {
            Write-Host ('Не удалось получить права администратора: ' + $_.Exception.Message) -ForegroundColor Red
            throw
        }
    }

    try {
        $folder = $env:TEMP
        $script:LogPath = Join-Path $folder ('WinRepair_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Start-Transcript -Path $script:LogPath -ErrorAction Stop | Out-Null
        $script:TranscriptOn = $true
        Write-Host ('Журнал WinRepair: ' + $script:LogPath)
    } catch {
        Write-Host ('Не удалось включить журнал действий: ' + $_.Exception.Message) -ForegroundColor Yellow
    }

    $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
    $version = [version]$os.Version
    $isServer = ([int]$os.ProductType -ne 1)
    $canRestoreHealth = ($version.Major -gt 6) -or (($version.Major -eq 6) -and ($version.Minor -ge 2))
    $edition = ''
    try { $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID } catch { }
    $profile = Get-OsImageProfile -OperatingSystem $os -Edition $edition -IsServer $isServer

    Write-Host '==============================================================='
    Write-Host 'WinRepair: проверка диска, DISM, SFC' -ForegroundColor Cyan
    Write-Host ('ОС: {0} (версия {1})' -f $os.Caption, $os.Version)
    Write-Host ('Редакция: {0}; тип: {1}' -f $edition, $(if ($isServer) { 'Server' } else { 'Client' }))
    Write-Host '==============================================================='
    Write-Host 'Скрипт не изменяет WSUS и не чистит кэш; запуск установки Windows и перезагрузка — только после подтверждения.'
    Write-Host 'Ctrl+C — прервать всю диагностику (включая текущую операцию).' -ForegroundColor Yellow

    Test-SystemVolume -OsVersion $version
    $skipWindowsRepair = $script:VolumeScheduled
    if ($script:VolumeNeedsAttention -and (-not $skipWindowsRepair)) {
        Write-Host 'Исправность файловой системы не подтверждена.' -ForegroundColor Yellow
        if (-not (Ask-YesNo 'Продолжить DISM/SFC несмотря на состояние диска?' $false)) {
            $skipWindowsRepair = $true
        }
    }
    if ($skipWindowsRepair) {
        Write-Host 'DISM и SFC пропущены; сначала исправьте файловую систему.' -ForegroundColor Yellow
    } else {
        if (-not $canRestoreHealth) {
            Write-Host ''
            Write-Host 'На Windows 7 / Windows Server 2008 R2 DISM /RestoreHealth не поддерживается.' -ForegroundColor Yellow
            Write-Host 'Будет выполнен только SFC. Для восстановления хранилища используйте KB947821 (CheckSUR).'
            Write-Host 'https://www.catalog.update.microsoft.com/Search.aspx?q=KB947821'
        } else {
            if ($isServer) {
                Write-Host ''
                Write-Host 'Windows Server: укажите ISO/WIM/ESD, если он доступен (Enter — без источника).' -ForegroundColor Yellow
                $script:DiskResult = Try-RepairFromImage -OsCaption $os.Caption -OsProfile $profile -IsServer $isServer
                if ($null -eq $script:DiskResult) {
                    Write-Host 'Источник не выбран. Запускается DISM с настройками источника по умолчанию.'
                    $script:DiskResult = Run-Dism -ImagePath $null -ImageIndex 0
                }
            } else {
                Write-Host "`nWindows Client: сначала DISM без ISO." -ForegroundColor Cyan
                $script:DiskResult = Run-Dism -ImagePath $null -ImageIndex 0
            }
            if (($script:DiskResult -ne 0) -and ($script:DiskResult -ne 3010)) {
                if ($null -eq $script:SelectedRepairImage) {
                    # The first attempt used the built-in/default source.
                    # A mounted ISO can now be entered without an extra Y/N prompt.
                    Write-Host ''
                    Write-Host 'DISM не смог восстановить Windows со штатным источником.' -ForegroundColor Yellow
                    $ret = Try-RepairFromImage -OsCaption $os.Caption -OsProfile $profile -IsServer $isServer
                    if ($null -ne $ret) { $script:DiskResult = $ret }
                    else { Write-Host 'Источник восстановления не выбран. Переходим к SFC.' -ForegroundColor Yellow }
                } elseif (Ask-YesNo 'Восстановление с выбранным образом не удалось. Попробовать другой ISO/WIM/ESD?' $true) {
                    $ret = Try-RepairFromImage -OsCaption $os.Caption -OsProfile $profile -IsServer $isServer -AskForDrive
                    if ($null -ne $ret) { $script:DiskResult = $ret }
                    else { Write-Host 'Повторное восстановление с ISO отменено. Исходная ошибка DISM сохраняется.' -ForegroundColor Yellow }
                }
            }
        }

        # SFC must NOT be in finally: Ctrl+C must not launch the next repair operation.
        Write-Host "`nПроверка системных файлов: SFC /scannow" -ForegroundColor Cyan
        $script:SfcResult = Invoke-RepairExecutable -Executable $script:SfcExe -Arguments '/scannow'
    }
    Write-Host ''
    Write-Host '====================== ИТОГ ======================' -ForegroundColor Cyan
    Write-Host ('Системный том: ' + $script:VolumeStatus)
    if ($script:VolumeScheduled) { Write-Host 'Исправление запланировано при загрузке.' -ForegroundColor Yellow }
    if ($null -ne $script:DiskResult) {
        Write-Host ('DISM: ' + (Format-ExitCode $script:DiskResult))
    } else {
        Write-Host 'DISM: не запускался или восстановление отменено.'
    }
    if ($null -ne $script:SfcResult) {
        Write-Host ('SFC:  ' + (Format-ExitCode $script:SfcResult))
    } else {
        Write-Host 'SFC: не запускался.'
    }
    Write-Host 'Результат SFC нужно оценить также по тексту его сообщения.'
    Write-Host ('DISM журнал: ' + (Join-Path $env:SystemRoot 'Logs\DISM\dism.log'))
    Write-Host ('CBS журнал:  ' + (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'))
    if ($script:LogPath -ne $null -and $script:TranscriptOn) {
        Write-Host ('Журнал WinRepair: ' + $script:LogPath)
    }
    if (($null -ne $script:DiskResult) -and ($script:DiskResult -ne 0) -and ($script:DiskResult -ne 3010)) {
        Write-Host 'DISM не восстановил хранилище. Проверьте сообщения DISM и CBS.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Если восстановление через DISM/ISO не помогает:' -ForegroundColor Yellow
        Write-Host '  Рассмотрите установку совместимой версии Windows поверх существующей.'
        Write-Host '  Из запущенной Windows смонтируйте ISO и запустите setup.exe.'
        Write-Host '  Выбирайте только «Сохранить личные файлы и приложения».'
        Write-Host '  Если такой вариант недоступен, отмените установку.'
        Write-Host '  Перед установкой создайте резервную копию важных данных.'
        $script:HadError = $true
    }
    if (($null -ne $script:SfcResult) -and ($script:SfcResult -ne 0)) { $script:HadError = $true }
    if ($script:VolumeNeedsAttention) { $script:HadError = $true }
    if ($script:DiskResult -eq 3010) { Write-Host 'DISM сообщил, что требуется перезагрузка (она не выполнялась).' -ForegroundColor Yellow }

    Write-Host ''
    Write-Host 'Для просмотра результата в новом окне PowerShell:' -ForegroundColor Cyan
    if ($script:LogPath -ne $null -and (Test-Path -LiteralPath $script:LogPath)) {
        # Quoting with doubled apostrophes keeps the command copyable even
        # when the log directory contains apostrophes.
        $quotedLog = $script:LogPath.Replace("'", "''")
        Write-Host ("Get-Content -LiteralPath '{0}' | Select-Object -Last 80" -f $quotedLog)
    } else {
        Write-Host 'Get-ChildItem "$env:TEMP\WinRepair_*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content | Select-Object -Last 80'
    }
    if (($null -ne $script:DiskResult) -and ($script:DiskResult -ne 0) -and ($script:DiskResult -ne 3010)) {
        Write-Host 'Последние характерные ошибки CBS:' -ForegroundColor Yellow
        Write-Host 'Select-String -Path "$env:windir\Logs\CBS\CBS.log" -Pattern "CSI Payload Corrupt","CBS_E_","Missing replacement","Failed to resolve","0x800f" | Select-Object -Last 30'
    }
    Write-Host '=================================================='
    if (($null -ne $script:DiskResult) -and ($script:DiskResult -ne 0) -and
        ($script:DiskResult -ne 3010) -and (-not $script:VolumeScheduled)) {
        Offer-InPlaceWindowsSetup -OsCaption $os.Caption -OsProfile $profile -IsServer $isServer -OsVersion $version
    }
    if ($script:VolumeScheduled) {
        Write-Host 'Сохраните файлы перед перезагрузкой; затем повторите WinRepair.'
        $script:RestartRequested = Ask-YesNo 'Перезагрузить компьютер сейчас?' $false
    }
    if ($script:RestartRequested) {
        try {
            Restart-Computer -ErrorAction Stop
            $script:RestartInitiated = $true
        } catch [System.Management.Automation.PipelineStoppedException] {
            throw
        } catch {
            Write-Host ('Не удалось перезагрузить компьютер: ' + $_.Exception.Message) -ForegroundColor Red
            $script:HadError = $true
        }
    }
} catch {
    # All unexpected failures, including cancellation, end the complete script.
    Write-Host ('Ошибка WinRepair: ' + $_.Exception.Message) -ForegroundColor Red
    throw
} finally {
    # Only cleanup belongs here. Never launch SFC after Ctrl+C.
    if ($script:TranscriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
    }
    # Also applies after launching Setup; never pause the launching instance
    # when it has handed off execution to a separate elevated process.
    if ((-not $script:ElevationStarted) -and (-not $script:RestartInitiated)) {
        Wait-ForExitKey
    }
}
if ($script:HadError) { exit 1 } else { exit 0 }
