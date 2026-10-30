# WinRepair

Windows repair diagnostics for **Windows 7/8/8.1/10/11** and compatible Windows Server versions. `WinRepair.ps1` checks the system volume with Repair-Volume/CHKDSK, then runs Microsoft's built-in DISM and SFC tools and helps select a compatible Windows installation image when the default repair source fails.

**[Русская документация](README.ru.md)**

> [!IMPORTANT]
> Run as an administrator and back up important data first. The tool can repair Windows system files and the component store, but it does not change WSUS policies, reset Windows Update caches, or remove components; reboot is available only after explicit confirmation. It is not a guarantee that component-store corruption can be fixed.

## Requirements

- Run `WinRepair.ps1` directly; no CMD launcher or supporting scripts are required.
- Windows PowerShell 2.0 or later for the repair script (including stock Windows 7); both 32-bit and 64-bit Windows are supported. Run from an interactive Windows console with access to DISM/SFC. The optional `update.ps1` requires **Windows PowerShell 5.1** and an internet connection.
- Administrator permissions. The PowerShell script requests UAC elevation when needed; on mapped network drives it attempts to convert the path to UNC before relaunching the same PS1 directly. If the elevated account cannot access the share, copy the script to a local drive.
- On Windows 8/Server 2012 or newer, DISM `/RestoreHealth` is supported. Windows 7/Server 2008 R2 uses SFC only; consider Microsoft CheckSUR (KB947821) for servicing-store repairs.

## Run

Right-click `WinRepair.ps1` and select **Run with PowerShell**, or invoke `& '.\WinRepair.ps1'` in a PowerShell console. It requests elevation with UAC if needed; Explorer-launched windows, including already-elevated launches, wait for a key at completion. Separately started PowerShell processes with `-File` / `-Command` also pause. It stays interactive and writes a PowerShell transcript to `%TEMP%\WinRepair\Logs` (subject to normal temporary-file cleanup). Windows-owned DISM/CBS logs remain at `%windir%\Logs\DISM\dism.log` and `%windir%\Logs\CBS\CBS.log`. Previously created `%ProgramData%\WinRepair\Logs` logs are not deleted automatically.

WinRepair first checks the **system volume** (`%SystemDrive%`, usually `C:`). On Windows 8 / Server 2012 or later it prefers `Repair-Volume -Scan` and can offer `-SpotFix` / `-OfflineScanAndFix`. On Windows 7 / Server 2008 R2, or when the cmdlet is unavailable, it falls back to read-only `chkdsk`. Scheduling a boot-time fix and an immediate reboot each require explicit confirmation. DISM/SFC are postponed if a boot repair is scheduled. `/r` is not run by default.

On Windows clients it first runs `DISM /Online /Cleanup-Image /RestoreHealth` using the default repair source. If this fails, it asks **`Y/N` (Enter defaults to Yes)** to try an install image. Windows Server prompts for an image before the first DISM attempt, allowing Enter to skip it. `SFC /scannow` follows DISM even when DISM fails, unless the operation is canceled.

Image discovery checks `sources\install.wim`, `sources\install.esd`, and the same filenames in the root of available drives. It does not recursively scan all folders. If no image is found, mount a Windows ISO and enter a drive **letter in Latin characters**, such as `E`, or the full path to the WIM/ESD. Image edition lists and image-index verification help choose the proper index. Automatic selection only occurs when the metadata uniquely matches; otherwise the user confirms. Windows and selected image versions are shown, including a warning when different.

The program runs DISM and SFC as native console processes, preserving their usual progress and signed exit codes. Image repair permits the standard Windows Update fallback (no `/LimitAccess`), but domain policies and the available repair source may restrict actual downloads. The script does not download an ISO, install Windows updates, or change those policies.

## Troubleshooting DISM failure (including 0x800F0915)

A matching Windows edition or image index **does not guarantee** that the chosen image contains the required component payload or revision. Windows Update fallback may also be unavailable on managed/WSUS computers. If DISM fails both with and without ISO, look for the accompanying download errors (for example, `0x800F0954` when Windows Update/WSUS cannot provide missing payloads). The tool does not alter WSUS or domain policies:

1. Review `%windir%\Logs\CBS\CBS.log` and `%windir%\Logs\DISM\dism.log` for the precise missing or corrupt component and error code. In PowerShell, a convenient excerpt is:

   ```powershell
   Select-String "$env:windir\Logs\CBS\CBS.log" -Pattern '0x800f0915','CSI Payload Corrupt','CBS_E_','Missing replacement','Failed to resolve' | Select-Object -Last 40
   ```

2. Obtain a repair source matching the installed Windows edition, language, architecture, servicing family, and required update level; re-run the repair. If DISM cannot restore the component store, consider an **in-place Windows installation from compatible ISO media**. Launch `setup.exe` from the running Windows desktop and select **Keep personal files and apps**; cancel if this option is unavailable. Back up important data before proceeding.
3. `SFC` reporting repaired files does **not** mean DISM has repaired the component store. Run DISM again or `DISM /Online /Cleanup-Image /ScanHealth` to reassess.

If the original console window closed, open PowerShell and read the most recent WinRepair log:

```powershell
Get-ChildItem "$env:TEMP\WinRepair\Logs\WinRepair_*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content | Select-Object -Last 80
```

When DISM fails, WinRepair prints an additional copyable one-line command to inspect recent CBS error signatures, without automatically dumping a large log.

See Microsoft's [Repair a Windows Image](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image) and [Configure a Windows Repair Source](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-a-windows-repair-source) guidance.

## Install or update from GitHub

Open **Windows PowerShell 5.1**, navigate to the desired installation directory, and run the following single block. The temporary updater is removed automatically:

```powershell
& {
    $f = Join-Path $env:TEMP ("WinRepair-Update-$([guid]::NewGuid().ToString('N')).ps1")
    $url = 'https://raw.githubusercontent.com/avmaksimov/WinRepair/main/update.ps1'
    try {
        Invoke-WebRequest -UseBasicParsing $url -OutFile $f -ErrorAction Stop
        & $f
    }
    finally {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
}
```

`update.ps1` is adapted from the [WinRE-Manager installer](https://github.com/avmaksimov/WinRE-Manager/blob/main/install.ps1). It uses the **current PowerShell working directory**, not the location of `update.ps1`. It downloads the GitHub source ZIP using `Invoke-WebRequest`, extracts it into `%TEMP%`, skips dot-prefixed files and folders, compares SHA-256 values, and lists every repository file as `INSTALL`, `REPLACE`, or `UNCHANGED`. It asks for **one `Y/N` confirmation** before changes. Files to be replaced are staged as `.new` next to their destination and then moved into place. Unchanged and unrelated files are left untouched; no old copies or updater logs are created. New repository files are discovered automatically, including files in subdirectories.

**Windows 7 with PowerShell 2.0:** download the ZIP manually and run `WinRepair.ps1`; the updater needs PowerShell 5.1. Network connectivity is required only for the updater and optional DISM Windows Update fallback, not for normal SFC.

The updater does not delete legacy `CheckWin-smart.cmd`, `CheckWin-smart.ps1`, or previously created log files; remove unused old scripts manually. No CMD file is included in this repository.

## Limitations

- `install.swm` split images are not supported.
- The ISO image version may differ from the installed OS or lack updated repair payloads; image selection is advisory, not proof of compatibility.
- The script is not a replacement for offline repairs or reinstalling Windows when the component store cannot be repaired.
- Ctrl+C attempts to interrupt the entire process; always inspect the final DISM/CBS state after interruption.

## Repository contents

```text
WinRepair.ps1
update.ps1
README.md
README.ru.md
LICENSE
```

License: [MIT](LICENSE).
