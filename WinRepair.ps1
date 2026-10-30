#requires -Version 2.0
<#
WinRepair: OS-aware Windows repair (Windows 7/Server 2008 R2 and newer).
- Windows client 8+: first try DISM with default source. Offer ISO/WIM/ESD on failure.
- Windows Server 2012+: ask for source immediately, but allow default source.
- Windows 7 / Server 2008 R2 and earlier: no unsupported RestoreHealth; run SFC.
- Run SFC after DISM, including failed DISM; Ctrl+C cancels the entire script.
- No WSUS policy changes, component cleanup, cache reset, or reboot; DISM may access Windows Update.
- Compatible with Windows PowerShell 2.0 (shipped with Windows 7).
#>
# Internal switch used by the elevated child to keep its console visible.
param([switch]$PauseAtExit)

# Keep the existing caller's PowerShell console open when elevating.
# A new elevated instance waits for a key before its window closes.
function Test-ExplorerLaunch {
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        $current = Get-WmiObject -Class Win32_Process -Filter ("ProcessId = {0}" -f $PID) -ErrorAction Stop
        if (($null -eq $current) -or ($current.CommandLine -notmatch '(?i)(?:^|\s)-(?:file|command)\b')) { return $false }
        $parent = Get-WmiObject -Class Win32_Process -Filter ("ProcessId = {0}" -f $current.ParentProcessId) -ErrorAction Stop
        return (($null -ne $parent) -and ($parent.Name -ieq 'explorer.exe'))
    } catch { return $false }
}
function Wait-ForExitKey {
    if (-not $script:PauseAtExit) { return }
    try {
        Write-Host ''
        Write-Host 'Press any key to finish...'
        [void][Console]::ReadKey($true)
    } catch { }
}
$script:PauseAtExit = ([bool]$PauseAtExit -or (Test-ExplorerLaunch))
$script:ElevationStarted = $false


$script:DiskResult = $null
$script:SfcResult = $null
$script:HadError = $false
$script:TranscriptOn = $false
$script:LogPath = $null
$script:ProgramDirectory = Join-Path $env:SystemRoot 'System32'
if (($env:PROCESSOR_ARCHITEW6432 -ne $null) -and ($env:PROCESSOR_ARCHITEW6432 -ne '')) {
    # Running 32-bit PowerShell on a 64-bit OS: use native system binaries.
    $script:ProgramDirectory = Join-Path $env:SystemRoot 'Sysnative'
}
$script:DismExe = Join-Path $script:ProgramDirectory 'dism.exe'
$script:SfcExe = Join-Path $script:ProgramDirectory 'sfc.exe'

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
    Write-Host ''
    Write-Host 'Смонтируйте ISO Windows и укажите БУКВУ его диска без двоеточия (например, E).' -ForegroundColor Cyan
    Write-Host 'При необходимости допускается полный путь к install.wim / install.esd.'
    Write-Host 'Enter — отменить попытку с образом и перейти к SFC.'
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
    $body = [string]::Join("`n", [string[]]$raw)
    $result = New-Object PSObject -Property @{
        Edition = ''; Architecture = ''; Installation = ''; Language = ''; Version = ''
    }
    foreach ($name in @('Edition', 'Architecture', 'Installation', 'Version')) {
        $match = [regex]::Match($body, ('(?im)^\s*{0}\s*:\s*(.*?)\s*$' -f $name))
        if ($match.Success) { $result.$name = $match.Groups[1].Value.Trim() }
    }
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
        Write-Host 'Отсутствие /LimitAccess не гарантирует доступ к Microsoft Update при действующих политиках WSUS.' -ForegroundColor Yellow
    }
    return $code
}

function Try-RepairFromImage {
    param([string]$OsCaption, $OsProfile, [bool]$IsServer)
    $image = Choose-Image
    if ($null -eq $image) { return $null }
    $index = Choose-ImageIndex -ImagePath $image -OsCaption $OsCaption -OsProfile $OsProfile -IsServer $IsServer
    if ($null -eq $index) { return $null }
    # The image name/edition may match while its servicing build differs.
    # Show the image version so the user can diagnose a missing repair payload.
    $details = Get-ImageDetails -ImagePath $image -ImageIndex $index
    if (($null -ne $details) -and (-not [string]::IsNullOrEmpty($details.Version))) {
        Write-Host ('Версия Windows: {0}; версия образа ISO: {1}' -f $OsProfile.Version, $details.Version)
        if (($OsProfile.Version -ne '') -and ($details.Version -ine $OsProfile.Version)) {
            Write-Host 'Версии отличаются: ISO может не содержать требуемые компоненты и их обновления.' -ForegroundColor Yellow
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
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -PauseAtExit' -f $scriptFile
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
        $folder = Join-Path $env:ProgramData 'WinRepair\Logs'
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        $script:LogPath = Join-Path $folder ('WinRepair_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Start-Transcript -Path $script:LogPath -ErrorAction Stop | Out-Null
        $script:TranscriptOn = $true
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
    Write-Host 'WinRepair: восстановление Windows (DISM, SFC)' -ForegroundColor Cyan
    Write-Host ('ОС: {0} (версия {1})' -f $os.Caption, $os.Version)
    Write-Host ('Редакция: {0}; тип: {1}' -f $edition, $(if ($isServer) { 'Server' } else { 'Client' }))
    Write-Host '==============================================================='
    Write-Host 'Скрипт не изменяет политики WSUS, не чистит кэш и не перезагружает ОС.'
    Write-Host 'Ctrl+C — прервать всю диагностику (включая текущую операцию).' -ForegroundColor Yellow

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
            if (Ask-YesNo 'DISM завершился ошибкой. Попробовать (другой) ISO/WIM/ESD?' $true) {
                $ret = Try-RepairFromImage -OsCaption $os.Caption -OsProfile $profile -IsServer $isServer
                if ($null -ne $ret) { $script:DiskResult = $ret }
                else { Write-Host 'Повторное восстановление с ISO отменено. Исходная ошибка DISM сохраняется.' -ForegroundColor Yellow }
            }
        }
    }

    # SFC must NOT be in finally: Ctrl+C must not launch the next repair operation.
    Write-Host "`nПроверка системных файлов: SFC /scannow" -ForegroundColor Cyan
    $script:SfcResult = Invoke-RepairExecutable -Executable $script:SfcExe -Arguments '/scannow' 
    Write-Host ''
    Write-Host '====================== ИТОГ ======================' -ForegroundColor Cyan
    if ($null -ne $script:DiskResult) {
        Write-Host ('DISM: ' + (Format-ExitCode $script:DiskResult))
    } else {
        Write-Host 'DISM: не запускался или восстановление отменено.'
    }
    Write-Host ('SFC:  ' + (Format-ExitCode $script:SfcResult))
    Write-Host 'Результат SFC нужно оценить также по тексту его сообщения.'
    Write-Host ('DISM журнал: ' + (Join-Path $env:SystemRoot 'Logs\DISM\dism.log'))
    Write-Host ('CBS журнал:  ' + (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'))
    if ($script:LogPath -ne $null -and $script:TranscriptOn) {
        Write-Host ('Журнал WinRepair: ' + $script:LogPath)
    }
    if (($null -ne $script:DiskResult) -and ($script:DiskResult -ne 0) -and ($script:DiskResult -ne 3010)) {
        Write-Host 'DISM не восстановил хранилище. Проверьте сообщения DISM и CBS.' -ForegroundColor Yellow
        $script:HadError = $true
    }
    if ($script:SfcResult -ne 0) { $script:HadError = $true }
    if ($script:DiskResult -eq 3010) { Write-Host 'DISM сообщил, что требуется перезагрузка (она не выполнялась).' -ForegroundColor Yellow }
    Write-Host '=================================================='
} catch {
    # All unexpected failures, including cancellation, end the complete script.
    Write-Host ('Ошибка WinRepair: ' + $_.Exception.Message) -ForegroundColor Red
    throw
} finally {
    # Only cleanup belongs here. Never launch SFC after Ctrl+C.
    if ($script:TranscriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
    }
    if (-not $script:ElevationStarted) { Wait-ForExitKey }
}
if ($script:HadError) { exit 1 } else { exit 0 }
