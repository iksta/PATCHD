<#
.SYNOPSIS
    Installs, updates or removes PATCHD.

.DESCRIPTION
    Install (default):
      * copies PATCHD into "C:\Program Files\PATCHD", which only administrators can change
      * adds a Start menu shortcut (and, if you want, a desktop shortcut) with the PATCHD icon
      * registers PATCHD in Settings > Apps so it can be uninstalled from there
      * points an existing nightly task at the new location
    Re-running the installer updates an existing install in place.

    Uninstall (-Uninstall, or Settings > Apps > PATCHD > Uninstall):
      * removes the shortcuts, the nightly task, the Settings > Apps entry and the program folder
      * keeps your settings, log and Steam backups in %LOCALAPPDATA%\PATCHD unless -RemoveUserData is given

    Uses only what ships with Windows. Asks for administrator approval when needed.

.EXAMPLE
    .\Install-PATCHD.ps1
    .\Install-PATCHD.ps1 -DesktopShortcut
    .\Install-PATCHD.ps1 -Uninstall -RemoveUserData
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$RemoveUserData,
    [switch]$DesktopShortcut,
    [switch]$NoDesktopShortcut,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$AppName     = 'PATCHD'
# Every path comes from Windows itself. Environment variables such as %ProgramFiles% or %SystemRoot% can be
# overridden per user, and this script runs as administrator, so they must not decide where files go or
# which programs get registered.
$System32    = [Environment]::SystemDirectory
$InstallDir  = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) $AppName
$PowerShell  = Join-Path $System32 'WindowsPowerShell\v1.0\powershell.exe'
$Icacls      = Join-Path $System32 'icacls.exe'
$StartMenu   = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'PATCHD.lnk'
$Desktop     = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'PATCHD.lnk'
$UninstKey   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PATCHD'
$TaskName    = 'PATCHD nightly updates'
$Files       = @('PATCHD.ps1', 'PATCHD.ico', 'Install-PATCHD.ps1')

function Write-Step([string]$Text) { Write-Host "  > $Text" -ForegroundColor Cyan }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-NotReparsePoint([string]$Path) {
    # Refuse to install into a junction or symbolic link: as administrator, that could redirect the copy
    # and the permission reset to a folder somewhere else.
    foreach ($p in @((Split-Path $Path), $Path)) {
        if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$p is a link to another location, so PATCHD won't install there."
        }
    }
}

function Get-AppVersion([string]$ScriptFile) {
    $m = [regex]::Match((Get-Content -LiteralPath $ScriptFile -Raw), "\`$script:Version\s*=\s*'([0-9.]+)'")
    if ($m.Success) { $m.Groups[1].Value } else { '0.0.0' }
}

function New-AppShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue   # recreated so its name matches exactly
        $lnk = $shell.CreateShortcut($Path)
        $lnk.TargetPath       = $PowerShell
        $lnk.Arguments        = "-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$InstallDir\PATCHD.ps1`""
        $lnk.WorkingDirectory = $InstallDir
        $lnk.IconLocation     = "$InstallDir\PATCHD.ico,0"
        $lnk.Description      = 'PATCHD - every installed game in one window, kept up to date'
        $lnk.WindowStyle      = 7   # start minimised so the PowerShell host never flashes up
        $lnk.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Install-App {
    $src = Split-Path -Parent $PSCommandPath
    if ($src.TrimEnd('\') -ieq $InstallDir) { throw 'Run the installer from the extracted download, not from the install folder.' }
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath (Join-Path $src $f) -PathType Leaf)) {
            throw "$f is missing next to the installer. Extract the whole release zip, then run Install.cmd again."
        }
    }
    $version = Get-AppVersion (Join-Path $src 'PATCHD.ps1')
    $upgrade = Test-Path -LiteralPath (Join-Path $InstallDir 'PATCHD.ps1')

    Assert-NotReparsePoint $InstallDir
    Write-Step ("{0} PATCHD {1} in {2}" -f $(if ($upgrade) { 'Updating' } else { 'Installing' }), $version, $InstallDir)
    # Older installs used different capitalisation (PatchD). Windows ignores case, so fix the folder's
    # displayed name with a two-step rename and replace the old files rather than overwriting them.
    $existing = Get-Item -LiteralPath $InstallDir -ErrorAction SilentlyContinue
    if ($existing -and $existing.Name -cne $AppName) {
        $temp = "$AppName.renaming"
        try {
            Rename-Item -LiteralPath $existing.FullName -NewName $temp
            Rename-Item -LiteralPath (Join-Path (Split-Path $InstallDir) $temp) -NewName $AppName
        } catch {
            # Cosmetic only (e.g. PATCHD is open): put the name back if the first step worked, and carry on.
            $tempPath = Join-Path (Split-Path $InstallDir) $temp
            if (Test-Path -LiteralPath $tempPath) { Rename-Item -LiteralPath $tempPath -NewName $existing.Name -ErrorAction SilentlyContinue }
        }
    }
    foreach ($f in $Files) { Remove-Item -LiteralPath (Join-Path $InstallDir $f) -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    foreach ($f in $Files) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $InstallDir -Force }
    Get-ChildItem -LiteralPath $InstallDir -File | Unblock-File

    # Program Files is writable only by administrators; make sure this folder inherits exactly that,
    # even if an older copy had different permissions.
    & $Icacls $InstallDir /reset /T /C /Q | Out-Null
    Write-Step 'Locked the program folder to administrators (inherited from Program Files)'

    New-AppShortcut $StartMenu
    Write-Step 'Added PATCHD to the Start menu'

    $wantDesktop = if ($DesktopShortcut) { $true }
                   elseif ($NoDesktopShortcut) { $false }
                   elseif (Test-Path -LiteralPath $Desktop) { $true }       # keep an existing one up to date
                   elseif ($Quiet) { $false }
                   else { (Read-Host '  Add a desktop shortcut too? [y/N]') -match '^(y|yes)$' }
    if ($wantDesktop) { New-AppShortcut $Desktop; Write-Step 'Added a desktop shortcut' }

    $size = [int](((Get-ChildItem -LiteralPath $InstallDir -File | Measure-Object Length -Sum).Sum) / 1KB)
    New-Item -Path $UninstKey -Force | Out-Null
    $values = [ordered]@{
        DisplayName     = 'PATCHD'
        DisplayVersion  = $version
        Publisher       = 'PATCHD contributors'
        DisplayIcon     = "$InstallDir\PATCHD.ico"
        InstallLocation = $InstallDir
        UninstallString = "`"$PowerShell`" -NoProfile -ExecutionPolicy RemoteSigned -File `"$InstallDir\Install-PATCHD.ps1`" -Uninstall"
    }
    foreach ($k in $values.Keys) { New-ItemProperty -Path $UninstKey -Name $k -Value $values[$k] -PropertyType String -Force | Out-Null }
    foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $UninstKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $UninstKey -Name 'EstimatedSize' -Value $size -PropertyType DWord -Force | Out-Null
    Write-Step 'Registered PATCHD in Settings > Apps'

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        try {
            $arg = "-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Minimized -File `"$InstallDir\PATCHD.ps1`" -UpdateAll"
            Set-ScheduledTask -TaskName $TaskName -Action (New-ScheduledTaskAction -Execute $PowerShell -Argument $arg) | Out-Null
            Write-Step 'Pointed your existing nightly task at this install'
        } catch {
            Write-Host "  ! Couldn't update the nightly task. Open PATCHD and press ARM again." -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host '  Done. Open PATCHD from the Start menu.' -ForegroundColor Green
}

function Uninstall-App {
    Write-Step 'Removing PATCHD'
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    foreach ($l in $StartMenu, $Desktop) { Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $UninstKey -Recurse -Force -ErrorAction SilentlyContinue
    Set-Location -LiteralPath $System32
    if (Test-Path -LiteralPath $InstallDir) {
        Assert-NotReparsePoint $InstallDir
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
    Write-Step 'Removed the shortcuts, nightly task, Settings > Apps entry and program folder'

    $data = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PATCHD'
    if ($RemoveUserData) {
        Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        Write-Step 'Removed your settings, log and Steam backups'
    } elseif (Test-Path -LiteralPath $data) {
        Write-Host "  Your settings, log and Steam backups were kept in $data" -ForegroundColor Gray
    }
    Write-Host '  Steam games keep the automatic-update setting they were given. Change it per game in Steam if you want.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  PATCHD has been removed.' -ForegroundColor Green
}

# --- Elevate if needed --------------------------------------------------------
if (-not (Test-Admin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($p in 'Uninstall', 'RemoveUserData', 'DesktopShortcut', 'NoDesktopShortcut', 'Quiet') {
        if ($PSBoundParameters.ContainsKey($p)) { $argList += "-$p" }
    }
    try {
        Start-Process -FilePath $PowerShell -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host 'PATCHD needs administrator approval to install into Program Files.' -ForegroundColor Yellow
    }
    return
}

# --- Run ----------------------------------------------------------------------
Write-Host ''
Write-Host '  PATCHD' -ForegroundColor Magenta
Write-Host ''
try {
    if ($Uninstall) { Uninstall-App } else { Install-App }
} catch {
    Write-Host ''
    Write-Host "  ! $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if (-not $Quiet) { Write-Host ''; [void](Read-Host '  Press Enter to close') }
}
