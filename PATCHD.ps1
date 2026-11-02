<#
.SYNOPSIS
    PATCHD - one window for every installed PC game, plus a hands-off "update window".

.DESCRIPTION
    Built only from what ships with Windows 10/11:
      * Windows PowerShell 5.1
      * WPF (PresentationFramework) for the UI
      * ScheduledTasks module for the optional nightly run

    Security posture
      * No third-party modules, no downloads, no compiled code (no Add-Type C#).
      * Makes no network calls itself. Launchers do their own updating.
      * Needs no admin rights.
      * Reads launcher manifests and registry keys read-only. The single exception is opt-in: it can set Steam's
        per-game "AutoUpdateBehavior" field (with Steam closed, after backing the file up to %LOCALAPPDATA%\PATCHD).
      * Writes only to %LOCALAPPDATA%\PATCHD (settings.json, update.log).
      * Only starts executables it found via each launcher's own registry entries or default install path.

    Launchers scanned: Steam, Epic, EA app, Ubisoft Connect, Battle.net, Wargaming Game Center.

.PARAMETER UpdateAll
    Headless mode (used by the "Run update window" button and the scheduled task):
    starts each enabled launcher that has games installed, waits for its disk/network
    activity to go quiet, optionally closes it again, logs everything, then exits.

.PARAMETER ListOnly
    Prints the detected games to the console and exits. Handy for a first test.

.EXAMPLE
    powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\PATCHD.ps1
    powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\PATCHD.ps1 -ListOnly
#>
[CmdletBinding()]
param(
    [switch]$UpdateAll,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Paths, settings, logging
# ---------------------------------------------------------------------------
$script:Version      = '1.0.0'
$script:ScriptPath   = $PSCommandPath
$script:DataDir      = Join-Path $env:LOCALAPPDATA 'PATCHD'
$script:LogFile      = Join-Path $script:DataDir 'update.log'
$script:SettingsFile = Join-Path $script:DataDir 'settings.json'
$script:TaskName     = 'PATCHD nightly updates'
$script:UpdateLock   = 'Local\PATCHD-UpdateWindow'   # held by a running update window
$script:StatusFile   = Join-Path $script:DataDir 'update-status.json'   # live launcher activity, written by the update window
# System paths come from Windows itself, never from environment variables a user-level program could override.
$script:PowerShellExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'

New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null

# ---------------------------------------------------------------------------
# Launcher registry. Each launcher is described once, by a Register-Launcher block in the LAUNCHERS
# section further down. Settings, signature checks, the launch-link allowlist, scanning, the update
# window and the UI all read from this registry, so a new launcher needs no changes anywhere else.
# ---------------------------------------------------------------------------
$script:LauncherDefs   = New-Object System.Collections.Generic.List[object]
$script:BlockedLogged  = @{}
$script:KnownLaunchers = @()
$script:Publishers     = @{}

function Register-Launcher([hashtable]$Definition) {
    $d = $Definition
    foreach ($key in 'Name', 'Publisher', 'FindExe', 'FindGames', 'Processes') {
        if (-not $d.ContainsKey($key) -or -not $d[$key]) { throw "Launcher definition is missing '$key'." }
    }
    if ($d.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9 .+-]{0,30}$') { throw "Invalid launcher name '$($d.Name)'." }
    if ($script:KnownLaunchers -contains $d.Name) { throw "Launcher '$($d.Name)' is registered twice." }
    $publishers = @($d.Publisher | Where-Object { $_ } | ForEach-Object { [string]$_ })
    foreach ($p in $publishers) { if ($p -notmatch '^[A-Za-z0-9][A-Za-z0-9 .,&()-]{1,80}$') { throw "$($d.Name): invalid Publisher '$p'." } }
    foreach ($key in 'FindExe', 'FindGames', 'ProcessFilter', 'GetPendingUpdates', 'Close') {
        if ($d.ContainsKey($key) -and $d[$key] -and $d[$key] -isnot [scriptblock]) { throw "$($d.Name): '$key' must be a script block." }
    }
    $schemes = @($d.UriSchemes | Where-Object { $_ })
    foreach ($sch in $schemes) {
        if ($sch -notmatch '^[a-z][a-z0-9.+-]{1,40}$' -or $sch -in 'http', 'https', 'file', 'ftp', 'ms-settings', 'shell') {
            throw "$($d.Name): URI scheme '$sch' is not allowed."
        }
    }
    $script:LauncherDefs.Add([pscustomobject]@{
        Name              = [string]$d.Name
        Publisher         = $publishers
        UriSchemes        = $schemes
        FindExe           = $d.FindExe
        StartArgs         = [string]$d.StartArgs
        Processes         = @($d.Processes)
        CloseProcesses    = $(if ($d.CloseProcesses) { @($d.CloseProcesses) } else { @($d.Processes) })
        ProcessFilter     = $d.ProcessFilter
        FindGames         = $d.FindGames
        GetPendingUpdates = $d.GetPendingUpdates
        Close             = $d.Close
    })
    $script:KnownLaunchers += [string]$d.Name
    $script:Publishers[[string]$d.Name] = $publishers
}

function Get-ClampedInt($Value, [int]$Min, [int]$Max, [int]$Default) {
    $n = 0
    if (-not [int]::TryParse([string]$Value, [ref]$n)) { return $Default }
    [Math]::Min($Max, [Math]::Max($Min, $n))
}

function Get-Settings {
    $s = [pscustomobject]@{
        EnabledLaunchers    = @($script:KnownLaunchers)
        WarmupMinutes       = 5
        IdleMinutes         = 5
        MaxMinutes          = 120
        IdleThresholdKBps   = 256
        CloseLaunchersAfter = $false
        SteamForceImmediate = $false
    }
    if (Test-Path -LiteralPath $script:SettingsFile) {
        try {
            $loaded = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $loaded.PSObject.Properties) {
                if ($s.PSObject.Properties[$p.Name]) { $s.($p.Name) = $p.Value }
            }
        } catch { }
    }
    # settings.json is user-writable: never trust its types or ranges.
    $s.EnabledLaunchers    = @($s.EnabledLaunchers | Where-Object { $_ -is [string] -and $script:KnownLaunchers -contains $_ })
    $s.WarmupMinutes       = Get-ClampedInt $s.WarmupMinutes 0 60 5
    $s.IdleMinutes         = Get-ClampedInt $s.IdleMinutes 1 60 5
    $s.MaxMinutes          = Get-ClampedInt $s.MaxMinutes 5 480 120
    $s.IdleThresholdKBps   = Get-ClampedInt $s.IdleThresholdKBps 16 100000 256
    $s.CloseLaunchersAfter = ($s.CloseLaunchersAfter -eq $true)
    $s.SteamForceImmediate = ($s.SteamForceImmediate -eq $true)
    $s
}

function Save-Settings($Settings) {
    $Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
}

function Write-Log([string]$Message) {
    try {
        if ((Test-Path -LiteralPath $script:LogFile) -and (Get-Item -LiteralPath $script:LogFile).Length -gt 1MB) {
            Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).old" -Force
        }
    } catch { }
    $Message = $Message -replace '[\x00-\x1F\x7F]', ' '
    # Logs get pasted into bug reports, so never write the Windows user folder (it contains the username).
    $userHome = [Environment]::GetFolderPath('UserProfile')
    if ($userHome -and $userHome.Length -gt 3) {
        $Message = [regex]::Replace($Message, [regex]::Escape($userHome), '%USERPROFILE%', 'IgnoreCase')
    }
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    if ($UpdateAll -or $ListOnly) { Write-Host $line }
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
function Get-RegValue([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function ConvertTo-SafeLocalPath([string]$Value) {
    # Paths come from registry keys and launcher files, some of which any program running as you can edit.
    # Only plain local paths (C:\...) are accepted. Rejected:
    #   * UNC and mapped network paths: merely checking them makes Windows send your NTLM credentials to that server
    #   * device paths (\\?\, \\.\), URLs, alternate data streams (file:stream)
    #   * PowerShell provider paths such as HKCU:\ or Cert:\ that Test-Path would otherwise accept
    if (-not $Value) { return $null }
    $v = $Value.Trim().Trim('"') -replace '/', '\'
    if ($v -notmatch '^[A-Za-z]:\\') { return $null }
    if ($v.IndexOf(':', 2) -ge 0) { return $null }
    if ($v.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) { return $null }
    try { $full = [System.IO.Path]::GetFullPath($v) } catch { return $null }
    if ($full -notmatch '^[A-Za-z]:\\') { return $null }
    try {
        if ((New-Object System.IO.DriveInfo($full.Substring(0, 1))).DriveType -eq [System.IO.DriveType]::Network) { return $null }
    } catch { return $null }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    $full
}

function Get-SafeDir([string]$Value) {
    $p = ConvertTo-SafeLocalPath $Value
    if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { $p } else { $null }
}

function Get-SafeFile([string]$Value, [string[]]$Extensions) {
    $p = ConvertTo-SafeLocalPath $Value
    if (-not $p) { return $null }
    if ($Extensions -and ($Extensions -notcontains [System.IO.Path]::GetExtension($p).ToLowerInvariant())) { return $null }
    if (Test-Path -LiteralPath $p -PathType Leaf) { $p } else { $null }
}

function Find-FirstFile([object[]]$Paths, [string[]]$Extensions = @('.exe')) {
    foreach ($p in $Paths) {
        $f = Get-SafeFile ([string]$p) $Extensions
        if ($f) { return $f }
    }
    $null
}

function Get-ProtocolExe([string]$Scheme) {
    # Resolves the exe registered for a URL scheme. Reads the machine-wide registration only:
    # HKEY_CLASSES_ROOT also merges per-user entries, which any program running as you can rewrite.
    try {
        $cmd = (Get-Item -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$Scheme\shell\open\command" -ErrorAction Stop).GetValue('')
    } catch { return $null }
    $exe = $null
    if ($cmd -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
    elseif ($cmd -match '^\s*(\S+)') { $exe = $Matches[1] }
    Get-SafeFile $exe @('.exe')
}

function Resolve-IconPath([string]$Value) {
    if (-not $Value) { return $null }
    $v = $Value.Trim().Trim('"') -replace ',\s*-?\d+$', ''
    Get-SafeFile $v.Trim().Trim('"') @('.exe', '.ico')
}


# Every launcher exe must carry a valid Authenticode signature from its registered Publisher before it is started or stopped.
$script:SigCache = @{}
function Get-CertOrganization($Certificate) {
    # Extracts O= from a certificate subject, handling quoted values such as O="Electronic Arts, Inc."
    if (-not $Certificate) { return $null }
    $m = [regex]::Match($Certificate.Subject, '(?:^|,\s*)O=(?:"((?:[^"]|"")*)"|([^,]*))')
    if (-not $m.Success) { return $null }
    $v = if ($m.Groups[1].Success) { $m.Groups[1].Value -replace '""', '"' } else { $m.Groups[2].Value }
    $v.Trim()
}

function Test-TrustedLauncherExe([string]$Path, [string]$Launcher) {
    if (-not $Path -or -not $script:Publishers.ContainsKey($Launcher)) { return $false }
    $key = "$Launcher|$Path".ToLowerInvariant()
    if (-not $script:SigCache.ContainsKey($key)) {
        $ok = $false
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            # The certificate's Organisation (O=) must exactly equal one of the launcher's registered publishers.
            $org = Get-CertOrganization $sig.SignerCertificate
            $ok = ($sig.Status -eq 'Valid') -and $org -and ($script:Publishers[$Launcher] -contains $org)
        } catch { }
        $script:SigCache[$key] = $ok
    }
    $script:SigCache[$key]
}

function Test-SafeLaunchUri([string]$Uri) {
    # Only schemes that a registered launcher declares in UriSchemes, with a strict character set.
    $schemes = @($script:LauncherDefs | ForEach-Object { $_.UriSchemes } | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) })
    if (-not $schemes.Count) { return $false }
    $Uri -match ('^(' + ($schemes -join '|') + ')://[A-Za-z0-9%/:?=&._-]+$')
}

function Format-Size([double]$Bytes) {
    if ($Bytes -le 0) { return '' }
    if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) } else { '{0:N0} MB' -f ($Bytes / 1MB) }
}

$script:UninstallCache = $null
function Get-UninstallCache {
    if ($null -eq $script:UninstallCache) {
        $roots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($r in $roots) {
            if (-not (Test-Path -LiteralPath $r)) { continue }
            foreach ($k in Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue) {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if (-not $p -or -not $p.DisplayName) { continue }
                $list.Add([pscustomobject]@{
                    Key             = $k.PSChildName
                    DisplayName     = [string]$p.DisplayName
                    Publisher       = [string]$p.Publisher
                    InstallLocation = [string]$p.InstallLocation
                    UninstallString = [string]$p.UninstallString
                    DisplayIcon     = [string]$p.DisplayIcon
                    EstimatedSizeKB = [double]$p.EstimatedSize
                })
            }
        }
        $script:UninstallCache = $list.ToArray()
    }
    $script:UninstallCache
}

function New-Game {
    param(
        [string]$Name, [string]$Launcher, [string]$Id, [string]$InstallPath,
        [double]$SizeBytes = 0, [string]$Status = 'Installed',
        [string]$LaunchUri, [string]$LaunchExe, [string]$LaunchArgs,
        [string]$ImagePath, [string]$IconPath,
        [string]$ManifestPath, [string]$UpdatePolicyCode
    )
    [pscustomobject]@{
        Name         = $Name
        Launcher     = $Launcher
        Id           = $Id
        InstallPath  = $InstallPath
        SizeBytes    = $SizeBytes
        Size         = (Format-Size $SizeBytes)
        Status       = $Status
        StatusKind   = (Get-StatusKind $Status)
        LaunchUri    = $LaunchUri
        LaunchExe    = $LaunchExe
        LaunchArgs   = $LaunchArgs
        ImagePath    = $ImagePath
        IconPath     = $IconPath
        Image        = $null
        ImageStretch = 'UniformToFill'
        ManifestPath     = $ManifestPath
        UpdatePolicyCode = $UpdatePolicyCode
        UpdatePolicy     = $(if ($UpdatePolicyCode) { $script:SteamPolicyNames[$UpdatePolicyCode] } else { '' })
    }
}

# ---------------------------------------------------------------------------
# Steam
# ---------------------------------------------------------------------------
function Get-SteamPath {
    $p = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    if (-not $p) { $p = Get-RegValue 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath' }
    Get-SafeDir $p
}

function ConvertFrom-VdfString([string]$s) { [regex]::Replace($s, '\\(.)', '$1') }

function Read-AcfValue([string]$Text, [string]$Key) {
    $m = [regex]::Match($Text, '(?im)^\s*"' + [regex]::Escape($Key) + '"\s+"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { ConvertFrom-VdfString $m.Groups[1].Value } else { $null }
}

function Get-SteamLibraries([string]$SteamPath) {
    $libs = New-Object System.Collections.Generic.List[string]
    $libs.Add($SteamPath)
    $vdf = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
        foreach ($m in [regex]::Matches($text, '"path"\s+"((?:[^"\\]|\\.)*)"')) {
            $p = Get-SafeDir (ConvertFrom-VdfString $m.Groups[1].Value)
            if ($p -and -not ($libs -contains $p)) { $libs.Add($p) }
        }
    }
    $libs.ToArray()
}

function Get-SteamStatus([string]$AcfText) {
    $flags = 0; [int]::TryParse((Read-AcfValue $AcfText 'StateFlags'), [ref]$flags) | Out-Null
    $toDl = 0.0; [double]::TryParse((Read-AcfValue $AcfText 'BytesToDownload'), [ref]$toDl) | Out-Null
    $done = 0.0; [double]::TryParse((Read-AcfValue $AcfText 'BytesDownloaded'), [ref]$done) | Out-Null
    if (($flags -band 1024) -or ($flags -band 256)) {
        if ($toDl -gt 0) { return ('Updating {0:N0}%' -f [Math]::Min(99, [Math]::Floor(100 * $done / $toDl))) }
        return 'Updating'
    }
    if ($flags -band 512) { return 'Update paused' }
    if (($flags -band 2) -or ($toDl -gt 0 -and $done -lt $toDl)) { return 'Update queued' }
    if ($flags -band 4) { return 'Installed' }
    'Installing'
}

function Get-StatusKind([string]$Status) {
    # Groups statuses for colouring: busy (cyan), pending (yellow), problem (magenta), ok (green).
    if ($Status -like 'Updating*' -or $Status -like 'Installing*') { return 'busy' }
    if ($Status -in 'Update queued', 'Update paused') { return 'pending' }
    if ($Status -eq 'Incomplete') { return 'problem' }
    'ok'
}

function Get-SteamGames([switch]$StatusOnly) {
    # -StatusOnly skips cover art, for the update window's frequent polling.
    $steam = Get-SteamPath
    if (-not $steam) { return }
    $cache = Join-Path $steam 'appcache\librarycache'
    foreach ($lib in Get-SteamLibraries $steam) {
        $apps = Join-Path $lib 'steamapps'
        if (-not (Test-Path -LiteralPath $apps)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
            if ($f.Length -gt 1MB) { continue }
            $t = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $t) { continue }
            $id = Read-AcfValue $t 'appid'
            if ($id -notmatch '^\d{1,10}$') { continue }
            if ($id -eq '228980') { continue }   # Steamworks Common Redistributables
            $name = Read-AcfValue $t 'name'
            if (-not $name) { $name = "Steam app $id" }
            $dir = Read-AcfValue $t 'installdir'
            # installdir must be a single folder name: no "..\" escapes, no absolute paths
            $dirOk = $dir -and $dir -notmatch '[\\/:]|^\.\.?$'
            # Soundtracks install to steamapps\music, not common: they are not games, so skip them.
            if ($dirOk -and (Get-SafeDir (Join-Path $apps "music\$dir"))) { continue }
            $path = if ($dirOk) { Get-SafeDir (Join-Path $apps "common\$dir") } else { $null }
            $size = 0.0; [double]::TryParse((Read-AcfValue $t 'SizeOnDisk'), [ref]$size) | Out-Null
            $img = $null
            if (-not $StatusOnly) {
                $img = Find-FirstFile @(
                    (Join-Path $cache "$id\library_600x900.jpg"),
                    (Join-Path $cache "${id}_library_600x900.jpg"),
                    (Join-Path $cache "$id\header.jpg"),
                    (Join-Path $cache "${id}_header.jpg"),
                    (Join-Path $cache "${id}_icon.jpg")
                ) -Extensions '.jpg', '.png'
                if (-not $img) {
                    # Current Steam layout: librarycache\<appid>\<hash>\library_header.jpg and similar.
                    $gameCache = Get-SafeDir (Join-Path $cache $id)
                    if ($gameCache) {
                        $files = @(Get-ChildItem -LiteralPath $gameCache -File -Recurse -ErrorAction SilentlyContinue |
                                   Where-Object { $_.Extension -in '.jpg', '.png' })
                        foreach ($want in 'library_header.jpg', 'header.jpg', 'library_capsule.jpg', 'library_600x900.jpg', 'library_hero.jpg') {
                            $hit = $files | Where-Object { $_.Name -eq $want } | Select-Object -First 1
                            if ($hit) { $img = Get-SafeFile $hit.FullName @('.jpg', '.png'); break }
                        }
                    }
                }
            }
            $policy = Read-AcfValue $t 'AutoUpdateBehavior'
            if ($policy -notmatch '^[012]$') { $policy = '0' }
            New-Game -Name $name -Launcher 'Steam' -Id $id -InstallPath $path -SizeBytes $size `
                     -Status (Get-SteamStatus $t) -LaunchUri "steam://rungameid/$id" -ImagePath $img `
                     -ManifestPath $f.FullName -UpdatePolicyCode $policy
        }
    }
}

function Find-GameExe([string]$Dir) {
    # Best guess at a game's main exe (for its icon only): the largest exe within two folder levels,
    # ignoring crash reporters, installers, anti-cheat and runtime redistributables.
    if (-not $Dir) { return $null }
    $skip = 'crash|redist|setup|install|unins|helper|report|anticheat|battleye|prereq|dxsetup|vc_?redist|dotnet|uploader|cefprocess|webhelper'
    $exe = Get-ChildItem -LiteralPath $Dir -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notmatch $skip } | Sort-Object Length -Descending | Select-Object -First 1
    if ($exe) { Get-SafeFile $exe.FullName @('.exe') } else { $null }
}

# Steam's per-game "Automatic updates" setting (game > Properties > Updates), stored in each appmanifest.
$script:SteamPolicyNames = @{ '0' = 'Steam decides'; '1' = 'On launch only'; '2' = 'Immediately' }

function Set-SteamAutoUpdate([object[]]$Games, [int]$Value) {
    # Rewrites only the AutoUpdateBehavior line of each appmanifest. Steam must be closed, because it keeps
    # these files in memory and would overwrite the change. Originals are backed up first.
    if ($Value -notin 0, 1, 2) { throw 'Invalid Steam update setting.' }
    if (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) { throw 'Steam is running. Close it before changing per-game update settings.' }
    $backupDir = Join-Path $script:DataDir ('steam-backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $changed = 0
    foreach ($g in $Games) {
        if ($g.Launcher -ne 'Steam') { continue }
        $file = Get-SafeFile $g.ManifestPath @('.acf')
        if (-not $file -or (Split-Path $file -Leaf) -notmatch '^appmanifest_\d{1,10}\.acf$') { continue }
        try {
            $text = [System.IO.File]::ReadAllText($file, $utf8)
            $re = '(?m)^([ \t]*"AutoUpdateBehavior"[ \t]+")\d+(")'
            if ([regex]::IsMatch($text, $re)) {
                $new = [regex]::Replace($text, $re, ('${1}' + $Value + '${2}'))
            } else {
                # Older manifests may lack the key: add it beneath StateFlags with matching indentation.
                $m = [regex]::Match($text, '(?m)^([ \t]*)"StateFlags"[ \t]+"[^"]*"')
                if (-not $m.Success) { Write-Log "Steam: unrecognised manifest for $($g.Name), left unchanged"; continue }
                $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
                $new = $text.Insert($m.Index + $m.Length, ($nl + $m.Groups[1].Value + '"AutoUpdateBehavior"' + "`t`t" + '"' + $Value + '"'))
            }
            if ($new -eq $text) { continue }
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            Copy-Item -LiteralPath $file -Destination (Join-Path $backupDir (Split-Path $file -Leaf)) -Force
            [System.IO.File]::WriteAllText($file, $new, $utf8)
            $changed++
        } catch {
            Write-Log "Steam: couldn't update $($g.Name): $($_.Exception.Message)"
        }
    }
    if ($changed) { Write-Log "Steam: set automatic updates to '$($script:SteamPolicyNames[[string]$Value])' for $changed game(s); originals backed up to $backupDir" }
    $changed
}

function Get-SteamBusyGames {
    # Games Steam itself reports as needing or receiving an update.
    @(Get-SteamGames -StatusOnly | Where-Object { $_.Status -in 'Updating', 'Update queued' })
}

# ---------------------------------------------------------------------------
# Epic
# ---------------------------------------------------------------------------
function Get-EpicGames {
    $dir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.item' -File -ErrorAction SilentlyContinue) {
        if ($f.Length -gt 1MB) { continue }
        try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($j.MainGameAppName -and $j.AppName -ne $j.MainGameAppName) { continue }   # DLC
        $loc = Get-SafeDir $j.InstallLocation
        if (-not $loc) { continue }
        $exe = if ($j.LaunchExecutable) { Find-FirstFile @(Join-Path $loc $j.LaunchExecutable) } else { $null }
        $status = if ($j.bIsIncompleteInstall) { 'Incomplete' } else { 'Installed' }
        $idsOk = -not (@($j.CatalogNamespace, $j.CatalogItemId, $j.AppName) | Where-Object { [string]$_ -notmatch '^[A-Za-z0-9._-]{1,128}$' })
        $uri = if ($idsOk) { 'com.epicgames.launcher://apps/{0}%3A{1}%3A{2}?action=launch&silent=true' -f $j.CatalogNamespace, $j.CatalogItemId, $j.AppName } else { $null }
        New-Game -Name $j.DisplayName -Launcher 'Epic' -Id $j.AppName -InstallPath $loc -SizeBytes ([double]$j.InstallSize) `
                 -Status $status -LaunchUri $uri -IconPath $exe
    }
}

# ---------------------------------------------------------------------------
# Ubisoft Connect
# ---------------------------------------------------------------------------
function Get-UbisoftGames {
    foreach ($base in 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs', 'HKLM:\SOFTWARE\Ubisoft\Launcher\Installs') {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue) {
            $id = $k.PSChildName
            if ($id -notmatch '^\d{1,10}$') { continue }
            $loc = Get-SafeDir (Get-RegValue $k.PSPath 'InstallDir')
            if (-not $loc) { continue }
            $u = Get-UninstallCache | Where-Object { $_.Key -eq "Uplay Install $id" } | Select-Object -First 1
            $name = if ($u) { $u.DisplayName } else { Split-Path $loc -Leaf }
            New-Game -Name $name -Launcher 'Ubisoft' -Id $id -InstallPath $loc -SizeBytes ($u.EstimatedSizeKB * 1KB) `
                     -LaunchUri "uplay://launch/$id/0" -IconPath (Resolve-IconPath $u.DisplayIcon)
        }
    }
}

# ---------------------------------------------------------------------------
# EA app
# ---------------------------------------------------------------------------
function Get-EaGames {
    foreach ($u in Get-UninstallCache) {
        $loc = Get-SafeDir $u.InstallLocation
        $isEa = ($u.UninstallString -match 'EAInstaller') -or
                ($u.Publisher -match 'Electronic Arts' -and $loc -and (Test-Path -LiteralPath (Join-Path $loc '__Installer')))
        if (-not $isEa -or -not $loc) { continue }
        if ($u.DisplayName -match '^(EA app|EA Desktop|Origin)$') { continue }
        $cid = $null
        $xml = Join-Path $loc '__Installer\installerdata.xml'
        if ((Test-Path -LiteralPath $xml -PathType Leaf) -and (Get-Item -LiteralPath $xml).Length -lt 1MB) {
            $m = [regex]::Match((Get-Content -LiteralPath $xml -Raw -Encoding UTF8), '<contentID>\s*([^<\s]+)\s*</contentID>')
            if ($m.Success -and $m.Groups[1].Value -match '^[A-Za-z0-9._:-]{1,128}$') { $cid = $m.Groups[1].Value }
        }
        $uri = if ($cid) { "origin2://game/launch?offerIds=$cid" } else { $null }
        New-Game -Name $u.DisplayName -Launcher 'EA' -Id $cid -InstallPath $loc -SizeBytes ($u.EstimatedSizeKB * 1KB) `
                 -LaunchUri $uri -IconPath (Resolve-IconPath $u.DisplayIcon)
    }
}

# ---------------------------------------------------------------------------
# Battle.net
# ---------------------------------------------------------------------------
function Get-BattleNetGames {
    foreach ($u in Get-UninstallCache) {
        if ($u.UninstallString -notmatch 'Battle\.net\\Agent|Blizzard Uninstaller') { continue }
        if ($u.DisplayName -eq 'Battle.net') { continue }
        $loc = Get-SafeDir $u.InstallLocation
        if (-not $loc) { continue }
        $uid = if ($u.UninstallString -match '--uid=([^\s"]+)') { $Matches[1] } else { $null }
        # Battle.net has no documented per-game launch URL, so "Play" opens Battle.net.
        New-Game -Name $u.DisplayName -Launcher 'Battle.net' -Id $uid -InstallPath $loc -SizeBytes ($u.EstimatedSizeKB * 1KB) `
                 -IconPath (Resolve-IconPath $u.DisplayIcon)
    }
}

# ---------------------------------------------------------------------------
# Wargaming Game Center
# ---------------------------------------------------------------------------
function Get-WargamingGames {
    foreach ($u in Get-UninstallCache) {
        $isWg = ($u.Publisher -match 'Wargaming') -or ($u.UninstallString -match 'Wargaming\.net\\GameCenter|\\wgc\.exe')
        if (-not $isWg -or $u.DisplayName -match 'Game Center') { continue }
        $loc = Get-SafeDir $u.InstallLocation
        if (-not $loc) { continue }
        New-Game -Name $u.DisplayName -Launcher 'Wargaming' -InstallPath $loc -SizeBytes ($u.EstimatedSizeKB * 1KB) `
                 -IconPath (Resolve-IconPath $u.DisplayIcon)
    }
}

# ===========================================================================
# LAUNCHERS
# One Register-Launcher block per launcher; CONTRIBUTING.md explains every field.
# Order matters: when two launchers report the same install folder (a Ubisoft game bought on Steam,
# say), the one registered first keeps it, so storefronts come before publisher launchers.
# ===========================================================================

Register-Launcher @{
    Name              = 'Steam'
    Publisher         = 'Valve Corp.'
    UriSchemes        = @('steam')
    FindExe           = {
        $steam = Get-SteamPath
        @($(if ($steam) { Join-Path $steam 'steam.exe' }), "${env:ProgramFiles(x86)}\Steam\steam.exe", (Get-ProtocolExe 'steam'))
    }
    StartArgs         = '-silent'
    Processes         = @('steam', 'steamwebhelper', 'steamservice')
    CloseProcesses    = @('steam')
    FindGames         = { Get-SteamGames }
    GetPendingUpdates = { Get-SteamBusyGames | ForEach-Object { $_.Name } }
    Close             = { param($Launcher) Start-Process -FilePath $Launcher.Exe -ArgumentList '-shutdown' }   # Steam's own clean shutdown
}

Register-Launcher @{
    Name           = 'Epic'
    Publisher      = 'Epic Games Inc.'
    UriSchemes     = @('com.epicgames.launcher')
    FindExe        = {
        @("${env:ProgramFiles(x86)}\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe",
          "${env:ProgramFiles(x86)}\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe",
          (Get-ProtocolExe 'com.epicgames.launcher'))
    }
    StartArgs      = '-silent'
    Processes      = @('EpicGamesLauncher', 'EpicWebHelper')
    FindGames      = { Get-EpicGames }
}

Register-Launcher @{
    Name           = 'Ubisoft'
    Publisher      = 'UBISOFT ENTERTAINMENT INC.'
    UriSchemes     = @('uplay')
    FindExe        = {
        $dir = Get-RegValue 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher' 'InstallDir'
        @($(if ($dir) { Join-Path $dir 'UbisoftConnect.exe' }), $(if ($dir) { Join-Path $dir 'upc.exe' }),
          "${env:ProgramFiles(x86)}\Ubisoft\Ubisoft Game Launcher\UbisoftConnect.exe", (Get-ProtocolExe 'uplay'))
    }
    Processes      = @('UbisoftConnect', 'upc', 'UplayWebCore')
    FindGames      = { Get-UbisoftGames }
}

Register-Launcher @{
    Name           = 'Battle.net'
    Publisher      = 'Blizzard Entertainment, Inc.'
    FindExe        = {
        $u = Get-UninstallCache | Where-Object { $_.DisplayName -eq 'Battle.net' } | Select-Object -First 1
        @($(if ($u -and $u.InstallLocation) { Join-Path $u.InstallLocation.Trim('"') 'Battle.net.exe' }),
          "${env:ProgramFiles(x86)}\Battle.net\Battle.net.exe", (Get-ProtocolExe 'battlenet'))
    }
    Processes      = @('Battle.net', 'Agent')        # Agent.exe does the actual patching
    CloseProcesses = @('Battle.net')
    ProcessFilter  = { param($Process) $Process.Name -ne 'Agent' -or ($Process.Path -like '*Battle.net*') }   # "Agent" is a generic name
    FindGames      = { Get-BattleNetGames }
}

Register-Launcher @{
    Name           = 'EA'
    Publisher      = 'Electronic Arts, Inc.'
    UriSchemes     = @('origin2')
    FindExe        = {
        $reg = 'HKLM:\SOFTWARE\Electronic Arts\EA Desktop'
        @((Get-RegValue $reg 'DesktopAppPath'), (Get-RegValue $reg 'LauncherAppPath'),
          "$env:ProgramFiles\Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe", (Get-ProtocolExe 'origin2'))
    }
    Processes      = @('EADesktop', 'EABackgroundService', 'EALocalHostSvc')
    CloseProcesses = @('EADesktop')
    FindGames      = { Get-EaGames }
}

Register-Launcher @{
    Name           = 'Wargaming'
    Publisher      = 'Wargaming Group Limited'
    FindExe        = {
        $u = Get-UninstallCache | Where-Object { $_.DisplayName -match 'Wargaming(\.net)? Game Center' } | Select-Object -First 1
        @((Join-Path $env:ProgramData 'Wargaming.net\GameCenter\wgc.exe'),
          $(if ($u -and $u.InstallLocation) { Join-Path $u.InstallLocation.Trim('"') 'wgc.exe' }))
    }
    Processes      = @('wgc', 'wgc_renderhost')
    FindGames      = { Get-WargamingGames }
}

# ---------------------------------------------------------------------------
# All games, de-duplicated by install folder (first registered launcher wins)
# ---------------------------------------------------------------------------
function Get-AllGames {
    $script:UninstallCache = $null
    $seen = @{}
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($d in $script:LauncherDefs) {
        try {
            foreach ($g in @(& $d.FindGames)) {
                if (-not $g -or -not $g.Name) { continue }
                $g.Launcher = $d.Name   # a scanner can only ever report games for its own launcher
                $k = if ($g.InstallPath) { $g.InstallPath.ToLowerInvariant() } else { "$($g.Launcher)|$($g.Name)" }
                if ($seen.ContainsKey($k)) { continue }
                $seen[$k] = $true
                $all.Add($g)
            }
        } catch {
            Write-Log "Scan of $($d.Name) failed: $($_.Exception.Message)"
        }
    }
    $all.ToArray() | Sort-Object Name
}

# ---------------------------------------------------------------------------
# Launchers at runtime: resolved exe, signature check, processes
# ---------------------------------------------------------------------------
function Get-LauncherInfo {
    foreach ($d in $script:LauncherDefs) {
        $exe = $null
        try { $exe = Find-FirstFile @(& $d.FindExe) } catch { Write-Log "$($d.Name): couldn't look up the launcher - $($_.Exception.Message)" }
        $l = [pscustomobject]@{
            Name = $d.Name; Exe = $exe; StartArgs = $d.StartArgs
            Procs = $d.Processes; CloseProcs = $d.CloseProcesses; Blocked = $false; Def = $d
        }
        if ($l.Exe -and -not (Test-TrustedLauncherExe $l.Exe $l.Name)) {
            if (-not $script:BlockedLogged.ContainsKey($l.Name)) {
                $script:BlockedLogged[$l.Name] = $true
                Write-Log "$($l.Name): '$($l.Exe)' is not validly signed by $($d.Publisher -join ' or ') - it will not be started"
            }
            $l.Exe = $null
            $l.Blocked = $true
        }
        $l
    }
}

function Get-LauncherProcesses($Launcher, [switch]$CloseSetOnly) {
    $names  = if ($CloseSetOnly) { $Launcher.CloseProcs } else { $Launcher.Procs }
    $filter = $Launcher.Def.ProcessFilter
    @(Get-Process -Name $names -ErrorAction SilentlyContinue | Where-Object { -not $filter -or (& $filter $_) })
}

function Get-PendingUpdateNames($Launcher) {
    if (-not $Launcher.Def.GetPendingUpdates) { return @() }
    try { @(& $Launcher.Def.GetPendingUpdates | Where-Object { $_ } | ForEach-Object { [string]$_ }) } catch { @() }
}

function Start-Launcher($Launcher) {
    $sp = @{ FilePath = $Launcher.Exe; WindowStyle = 'Minimized'; WorkingDirectory = (Split-Path $Launcher.Exe) }
    if ($Launcher.StartArgs) { $sp.ArgumentList = $Launcher.StartArgs }
    Start-Process @sp
}

function Wait-Briefly([double]$Seconds, [scriptblock]$OnWait) {
    # With $OnWait (the UI passes one), wait in short steps so the window keeps repainting.
    if (-not $OnWait) { Start-Sleep -Seconds $Seconds; return }
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) { & $OnWait; Start-Sleep -Milliseconds 200 }
}

function Stop-Launcher($Launcher, [scriptblock]$OnWait) {
    if ($Launcher.Def.Close -and $Launcher.Exe) {
        # The launcher's own clean shutdown, then wait for it to finish.
        & $Launcher.Def.Close $Launcher
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-LauncherProcesses $Launcher -CloseSetOnly).Count -and (Get-Date) -lt $deadline) { Wait-Briefly 2 $OnWait }
        return
    }
    # Only touch processes whose exe is signed by this launcher's publisher, never a same-named stranger.
    $mine = { Get-LauncherProcesses $Launcher -CloseSetOnly | Where-Object { $_.Path -and (Test-TrustedLauncherExe $_.Path $Launcher.Name) } }
    foreach ($p in & $mine) { try { [void]$p.CloseMainWindow() } catch { } }
    Wait-Briefly 20 $OnWait
    & $mine | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-IoRatesByPid([int[]]$ProcessIds) {
    # "IO Data Bytes/sec" covers disk and network I/O for a process (built-in perf counters, no extra tools).
    # One query for every launcher process at once: these queries are expensive for Windows, so batch them.
    $rates = @{}
    if (-not $ProcessIds) { return $rates }
    $filter = ($ProcessIds | Select-Object -Unique | ForEach-Object { "IDProcess=$_" }) -join ' OR '
    foreach ($r in @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -Filter $filter -ErrorAction SilentlyContinue)) {
        $rates[[int]$r.IDProcess] = [double]$r.IODataBytesPersec / 1KB
    }
    $rates
}

# ---------------------------------------------------------------------------
# Update window (headless)
# ---------------------------------------------------------------------------
function Invoke-UpdateWindow {
    $mutex = New-Object System.Threading.Mutex($false, $script:UpdateLock)
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Write-Log 'An update window is already running, so this one was not started.'; return }

    try {
        # Run at low priority: the launchers do the heavy lifting, PATCHD only watches.
        try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
        $s = Get-Settings
        Write-Log '=== Update window started ==='
        $games = @(Get-AllGames)
        $active = New-Object System.Collections.Generic.List[object]

        if ($s.SteamForceImmediate -and $s.EnabledLaunchers -contains 'Steam') {
            $todo = @($games | Where-Object { $_.Launcher -eq 'Steam' -and $_.UpdatePolicyCode -ne '2' })
            if ($todo.Count) {
                if (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) {
                    Write-Log "Steam: already running, so $($todo.Count) game(s) not set to 'Immediately' were left as they are tonight"
                } else {
                    try { [void](Set-SteamAutoUpdate $todo 2) } catch { Write-Log "Steam: $($_.Exception.Message)" }
                }
            }
        }

        foreach ($l in Get-LauncherInfo) {
            if ($s.EnabledLaunchers -notcontains $l.Name) { continue }
            $count = @($games | Where-Object { $_.Launcher -eq $l.Name }).Count
            if ($count -eq 0) { continue }
            if (-not $l.Exe) { Write-Log "$($l.Name): $count game(s) found but launcher exe not found - skipping"; continue }
            $wasRunning = (Get-LauncherProcesses $l -CloseSetOnly).Count -gt 0
            if ($wasRunning) {
                Write-Log "$($l.Name): already running - will monitor but leave it open ($count games)"
            } else {
                Write-Log "$($l.Name): starting launcher ($count games)"
                try { Start-Launcher $l } catch { Write-Log "$($l.Name): failed to start - $($_.Exception.Message)"; continue }
            }
            $active.Add([pscustomobject]@{ L = $l; WasRunning = $wasRunning; IdleSince = $null; Done = $false; Pids = @(); State = 'starting'; Rate = 0 })
        }

        if ($active.Count -eq 0) { Write-Log 'No enabled launchers with installed games - nothing to do.'; return }

        foreach ($a in $active) {
            $names = Get-PendingUpdateNames $a.L
            if ($names.Count) { Write-Log ("{0} reports pending updates for: {1}" -f $a.L.Name, ($names -join ', ')) }
        }

        $start = Get-Date
        Save-UpdateStatus $active 'warm-up'
        Write-Log "Warm-up: waiting $($s.WarmupMinutes) min for launchers to sign in and check for updates"
        Start-Sleep -Seconds ([int]$s.WarmupMinutes * 60)

        while ($true) {
            $pending = @($active | Where-Object { -not $_.Done })
            if ($pending.Count -eq 0) { break }
            if (((Get-Date) - $start).TotalMinutes -ge $s.MaxMinutes) {
                Write-Log "Reached the $($s.MaxMinutes) min limit - stopping monitoring (still busy: $(($pending | ForEach-Object { $_.L.Name }) -join ', '))"
                break
            }
            # Sample every pending launcher together: three batched queries per pass in total.
            foreach ($a in $pending) { $a.Pids = @(Get-LauncherProcesses $a.L | ForEach-Object { $_.Id }) }
            $allPids = @($pending | ForEach-Object { $_.Pids })
            $samples = @()
            if ($allPids.Count) {
                $samples = foreach ($n in 1..3) { Get-IoRatesByPid $allPids; Start-Sleep -Seconds 2 }
            }

            foreach ($a in $pending) {
                $name = $a.L.Name
                if ($a.Pids.Count -eq 0) { Write-Log "${name}: launcher is no longer running - treating as finished"; $a.Done = $true; $a.State = 'closed'; continue }

                $pids = $a.Pids
                $rate = (@($samples | ForEach-Object {
                    $h = $_
                    ($pids | ForEach-Object { if ($h.ContainsKey([int]$_)) { $h[[int]$_] } else { 0 } } | Measure-Object -Sum).Sum
                }) | Measure-Object -Average).Average
                if (-not $rate) { $rate = 0 }
                $a.Rate = $rate
                $busy = $rate -ge $s.IdleThresholdKBps
                $a.State = if ($busy) { 'downloading' } else { 'quiet' }
                if ((Get-PendingUpdateNames $a.L).Count) {   # the launcher itself says updates are still queued
                    $busy = $true
                    if ($a.State -eq 'quiet') { $a.State = 'pending' }
                }

                if ($busy) {
                    if ($a.IdleSince) { Write-Log ("{0}: activity resumed ({1:N0} KB/s)" -f $name, $rate) }
                    $a.IdleSince = $null
                } elseif (-not $a.IdleSince) {
                    $a.IdleSince = Get-Date
                }

                if ($a.IdleSince -and ((Get-Date) - $a.IdleSince).TotalMinutes -ge $s.IdleMinutes) {
                    $a.Done = $true
                    $a.State = 'done'
                    Write-Log "${name}: quiet for $($s.IdleMinutes) min - finished"
                    if ($s.CloseLaunchersAfter -and -not $a.WasRunning) {
                        Write-Log "${name}: closing launcher"
                        Stop-Launcher $a.L
                    }
                }
            }
            Save-UpdateStatus $active 'monitoring'
            Start-Sleep -Seconds 30
        }

        foreach ($a in $active) {
            $names = Get-PendingUpdateNames $a.L
            if ($names.Count) { Write-Log ("{0} still has pending updates: {1}" -f $a.L.Name, ($names -join ', ')) }
        }
        Write-Log ('=== Update window finished after {0:N0} min ===' -f ((Get-Date) - $start).TotalMinutes)
    }
    finally {
        Remove-Item -LiteralPath $script:StatusFile -Force -ErrorAction SilentlyContinue
        if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Save-UpdateStatus($Active, [string]$Phase) {
    # A tiny JSON file the PATCHD window reads to show live launcher activity without doing the measuring itself.
    try {
        [pscustomobject]@{
            Updated   = (Get-Date).ToString('o')
            Phase     = $Phase
            Launchers = @($Active | ForEach-Object { [pscustomobject]@{ Name = $_.L.Name; State = $_.State; KBps = [Math]::Round([double]$_.Rate) } })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:StatusFile -Encoding UTF8
    } catch { }
}

function Get-UpdateWindowProcess {
    # Returns the running update window's process (from any start: button, schedule or command line), or $null.
    $lock = $null
    if (-not [System.Threading.Mutex]::TryOpenExisting($script:UpdateLock, [ref]$lock)) { return $null }
    $lock.Dispose()
    $proc = Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'PATCHD\.ps1' -and $_.CommandLine -match '-UpdateAll' } |
            Select-Object -First 1
    if ($proc) { $proc } else { [pscustomobject]@{ ProcessId = 0; CreationDate = $null } }
}

# ---------------------------------------------------------------------------
# Scheduled task (built-in ScheduledTasks module, runs as you, no admin)
# ---------------------------------------------------------------------------
function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-FolderWritableByMe([string]$Dir) {
    # Tries to create and remove a throwaway file. Success means any program running as you could also
    # replace PATCHD.ps1 here.
    $probe = Join-Path $Dir ('.patchd-write-test-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        $true
    } catch { $false }
}

function Register-UpdateTask([datetime]$At) {
    $scriptFile = ConvertTo-SafeLocalPath $script:ScriptPath
    if (-not $scriptFile) { throw 'PATCHD.ps1 must be on a local drive to be scheduled.' }
    if (Test-IsElevated) {
        throw 'Open PATCHD normally, not as administrator, to set up the nightly schedule.'
    }
    if (Test-FolderWritableByMe (Split-Path $scriptFile)) {
        throw ("PATCHD is running from a folder that ordinary programs can change, so a nightly task could be hijacked.`n`n" +
               "Install it with Install.cmd and open it from the Start menu, then schedule from there.")
    }
    $arg = "-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Minimized -File `"$($script:ScriptPath)`" -UpdateAll"
    $action    = New-ScheduledTaskAction -Execute $script:PowerShellExe -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -Daily -At $At
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -AllowStartIfOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'Starts game launchers so they can install updates (PATCHD).' -Force | Out-Null
}

function Get-ScheduleText {
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return '> SCHEDULE: OFFLINE' }
    $tr = $t.Triggers | Select-Object -First 1
    try { '> SCHEDULE: ARMED // DAILY ' + ([datetime]$tr.StartBoundary).ToString('HH:mm') } catch { '> SCHEDULE: ARMED' }
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PATCHD" Width="1280" Height="800" MinWidth="980" MinHeight="580"
        WindowStyle="None" ResizeMode="CanResize"
        Background="#07080D" Foreground="#D8E1F0" FontFamily="Bahnschrift, Segoe UI" FontSize="13"
        WindowStartupLocation="CenterScreen">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="72" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <FontFamily x:Key="Mono">Cascadia Mono, Consolas</FontFamily>
    <SolidColorBrush x:Key="Cyan" Color="#00F0FF"/>
    <SolidColorBrush x:Key="Magenta" Color="#FF2BD6"/>
    <SolidColorBrush x:Key="Yellow" Color="#FCEE0A"/>
    <SolidColorBrush x:Key="Dim" Color="#6E7A91"/>

    <!-- Angular neon button: hover fills with its border colour and glows -->
    <Style TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#00F0FF"/>
      <Setter Property="BorderBrush" Value="#00F0FF"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="1" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Path Data="M0,0 L7,0 L0,7 Z" Fill="{TemplateBinding BorderBrush}" HorizontalAlignment="Left" VerticalAlignment="Top"/>
              <Path Data="M7,0 L7,7 L0,7 Z" Fill="{TemplateBinding BorderBrush}" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter Property="Foreground" Value="#05060A"/>
                <Setter TargetName="b" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#00F0FF" BlurRadius="18" ShadowDepth="0" Opacity="0.8"/></Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#FCEE0A"/>
      <Setter Property="BorderBrush" Value="#FCEE0A"/>
      <Setter Property="Foreground" Value="#05060A"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Effect">
        <Setter.Value><DropShadowEffect Color="#FCEE0A" BlurRadius="14" ShadowDepth="0" Opacity="0.45"/></Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Hot" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Foreground" Value="#FF2BD6"/>
      <Setter Property="BorderBrush" Value="#FF2BD6"/>
    </Style>

    <!-- Title-bar buttons -->
    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Width" Value="42"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="#6E7A91"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1A00F0FF"/>
                <Setter Property="Foreground" Value="#00F0FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="WinClose" TargetType="Button" BasedOn="{StaticResource WinBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#FF2BD6"/>
                <Setter Property="Foreground" Value="#05060A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Terminal-style text input -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#05060A"/>
      <Setter Property="Foreground" Value="#D8E1F0"/>
      <Setter Property="BorderBrush" Value="#3300F0FF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush" Value="#00F0FF"/>
      <Setter Property="SelectionBrush" Value="#FF2BD6"/>
      <Setter Property="FontFamily" Value="{StaticResource Mono}"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <!-- No Margin here: the TextBox already applies its own Padding to this host. -->
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#8800F0FF"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#FF2BD6"/>
                <Setter TargetName="b" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#FF2BD6" BlurRadius="10" ShadowDepth="0" Opacity="0.6"/></Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Square neon checkbox -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#D8E1F0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="box" Width="16" Height="16" BorderBrush="#00F0FF" BorderThickness="1" Background="#05060A" VerticalAlignment="Center">
                <Rectangle x:Name="fill" Margin="3" Fill="#00F0FF" Visibility="Collapsed">
                  <Rectangle.Effect><DropShadowEffect Color="#00F0FF" BlurRadius="8" ShadowDepth="0"/></Rectangle.Effect>
                </Rectangle>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="fill" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="#FF2BD6"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Thin neon scrollbars -->
    <ControlTemplate x:Key="VScroll" TargetType="ScrollBar">
      <Grid Background="#0A0C12" Width="8">
        <Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.Thumb>
            <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#00F0FF" Opacity="0.55" Margin="1,0"/></ControlTemplate></Thumb.Template></Thumb>
          </Track.Thumb>
        </Track>
      </Grid>
    </ControlTemplate>
    <ControlTemplate x:Key="HScroll" TargetType="ScrollBar">
      <Grid Background="#0A0C12" Height="8">
        <Track x:Name="PART_Track" IsDirectionReversed="False">
          <Track.Thumb>
            <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#FF2BD6" Opacity="0.55" Margin="0,1"/></ControlTemplate></Thumb.Template></Thumb>
          </Track.Thumb>
        </Track>
      </Grid>
    </ControlTemplate>
    <Style TargetType="ScrollBar">
      <Setter Property="Template" Value="{StaticResource VScroll}"/>
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Template" Value="{StaticResource HScroll}"/>
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/>
          <Setter Property="MinHeight" Value="8"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Section label -->
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#00F0FF"/>
      <Setter Property="FontFamily" Value="{StaticResource Mono}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Effect"><Setter.Value><DropShadowEffect Color="#00F0FF" BlurRadius="8" ShadowDepth="0" Opacity="0.6"/></Setter.Value></Setter>
    </Style>

    <!-- Launcher filter chip -->
    <Style x:Key="Chip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#9AA6BD"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid>
              <Border x:Name="b" Background="#0B0D14" BorderBrush="#2A00F0FF" BorderThickness="1" Padding="14,5">
                <ContentPresenter/>
              </Border>
              <Path x:Name="notch" Data="M6,0 L6,6 L0,6 Z" Fill="#2A00F0FF" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#00F0FF"/>
                <Setter Property="Foreground" Value="#00F0FF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#FF2BD6"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#FF2BD6"/>
                <Setter TargetName="notch" Property="Fill" Value="#FCEE0A"/>
                <Setter Property="Foreground" Value="#05060A"/>
                <Setter TargetName="b" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#FF2BD6" BlurRadius="14" ShadowDepth="0" Opacity="0.7"/></Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Panel with neon corner brackets -->
    <Style x:Key="Frame" TargetType="ContentControl">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContentControl">
            <Grid>
              <Border Background="#D90A0C13" BorderBrush="#2200F0FF" BorderThickness="1" Padding="{TemplateBinding Padding}">
                <ContentPresenter/>
              </Border>
              <Path Data="M0,14 L0,0 L14,0" Stroke="#00F0FF" StrokeThickness="2" HorizontalAlignment="Left" VerticalAlignment="Top"/>
              <Path Data="M0,0 L14,0 L14,14" Stroke="#00F0FF" StrokeThickness="2" HorizontalAlignment="Right" VerticalAlignment="Top"/>
              <Path Data="M0,0 L0,14 L14,14" Stroke="#FF2BD6" StrokeThickness="2" HorizontalAlignment="Left" VerticalAlignment="Bottom"/>
              <Path Data="M0,14 L14,14 L14,0" Stroke="#FF2BD6" StrokeThickness="2" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" BorderBrush="#4400F0FF" BorderThickness="1">
    <Grid>
      <!-- Background grid -->
      <Grid.Background>
        <DrawingBrush TileMode="Tile" Viewport="0,0,44,44" ViewportUnits="Absolute">
          <DrawingBrush.Drawing>
            <GeometryDrawing Brush="#07080D">
              <GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,44,44"/></GeometryDrawing.Geometry>
              <GeometryDrawing.Pen><Pen Brush="#0C1720" Thickness="1"/></GeometryDrawing.Pen>
            </GeometryDrawing>
          </DrawingBrush.Drawing>
        </DrawingBrush>
      </Grid.Background>

      <!-- Ambient neon glows -->
      <Rectangle IsHitTestVisible="False">
        <Rectangle.Fill>
          <RadialGradientBrush Center="1,0" GradientOrigin="1,0" RadiusX="0.7" RadiusY="0.8">
            <GradientStop Color="#33FF2BD6" Offset="0"/>
            <GradientStop Color="#00FF2BD6" Offset="1"/>
          </RadialGradientBrush>
        </Rectangle.Fill>
      </Rectangle>
      <Rectangle IsHitTestVisible="False">
        <Rectangle.Fill>
          <RadialGradientBrush Center="0,1" GradientOrigin="0,1" RadiusX="0.7" RadiusY="0.8">
            <GradientStop Color="#2600F0FF" Offset="0"/>
            <GradientStop Color="#0000F0FF" Offset="1"/>
          </RadialGradientBrush>
        </Rectangle.Fill>
      </Rectangle>

      <Grid Margin="20,0,20,18">
        <Grid.RowDefinitions>
          <RowDefinition Height="72"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="0.5*" MinWidth="340" MaxWidth="600"/>
        </Grid.ColumnDefinitions>

        <!-- Title bar / header (draggable) -->
        <DockPanel Grid.Row="0" Grid.ColumnSpan="2" LastChildFill="False">
          <StackPanel DockPanel.Dock="Left" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <Grid>
                <TextBlock Text="PATCHD" FontSize="30" FontWeight="Bold" Foreground="#FF2BD6" Opacity="0.75" Margin="-2,1,0,0"/>
                <TextBlock Text="PATCHD" FontSize="30" FontWeight="Bold" Foreground="#00F0FF" Opacity="0.75" Margin="2,-1,0,0"/>
                <TextBlock Text="PATCHD" FontSize="30" FontWeight="Bold" Foreground="#F4F7FF">
                  <TextBlock.Effect><DropShadowEffect Color="#00F0FF" BlurRadius="18" ShadowDepth="0" Opacity="0.7"/></TextBlock.Effect>
                </TextBlock>
              </Grid>
              <Border Background="#FCEE0A" Margin="12,6,0,0" Padding="6,1" VerticalAlignment="Center">
                <TextBlock x:Name="VersionBadge" Text="LIBRARY.SYS" Foreground="#05060A" FontFamily="{StaticResource Mono}" FontSize="10" FontWeight="Bold"/>
              </Border>
            </StackPanel>
            <TextBlock x:Name="Summary" Foreground="#6E7A91" FontFamily="{StaticResource Mono}" FontSize="12" Text="&gt; SCANNING LAUNCHERS..."/>
          </StackPanel>

          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top" Margin="0,0,-12,0">
            <Button x:Name="BtnMin" Style="{StaticResource WinBtn}" Content="&#xE921;"/>
            <Button x:Name="BtnMax" Style="{StaticResource WinBtn}" Content="&#xE922;"/>
            <Button x:Name="BtnClose" Style="{StaticResource WinClose}" Content="&#xE8BB;"/>
          </StackPanel>
          <Button x:Name="Refresh" DockPanel.Dock="Right" Content="RESCAN" Margin="10,0,24,0" VerticalAlignment="Center"/>
          <Grid DockPanel.Dock="Right" Width="300" VerticalAlignment="Center">
            <TextBox x:Name="Search" Height="34" Padding="26,5,8,5"/>
            <TextBlock Text="&gt;" Foreground="#FF2BD6" FontFamily="{StaticResource Mono}" Margin="10,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            <TextBlock x:Name="SearchHint" Text="search_games" Foreground="#4A5568" FontFamily="{StaticResource Mono}"
                       Margin="27,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
          </Grid>
        </DockPanel>

        <!-- Neon divider -->
        <Rectangle Grid.Row="1" Grid.ColumnSpan="2" Height="2" Margin="0,0,0,14">
          <Rectangle.Fill>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#00F0FF" Offset="0"/>
              <GradientStop Color="#FF2BD6" Offset="0.55"/>
              <GradientStop Color="#FCEE0A" Offset="0.85"/>
              <GradientStop Color="#00FCEE0A" Offset="1"/>
            </LinearGradientBrush>
          </Rectangle.Fill>
          <Rectangle.Effect><DropShadowEffect Color="#FF2BD6" BlurRadius="12" ShadowDepth="0" Opacity="0.8"/></Rectangle.Effect>
        </Rectangle>

        <!-- Launcher filter chips -->
        <WrapPanel x:Name="Chips" Grid.Row="2" Grid.Column="0" Margin="0,0,0,4"/>

        <!-- Game list -->
        <ContentControl Grid.Row="3" Grid.Column="0" Style="{StaticResource Frame}" Padding="6">
          <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single"
                    HeadersVisibility="Column" GridLinesVisibility="None" BorderThickness="0"
                    Background="Transparent" RowBackground="Transparent" AlternatingRowBackground="#0800F0FF"
                    Foreground="#D8E1F0" RowHeight="50" CanUserResizeRows="False" CanUserAddRows="False">
            <DataGrid.ColumnHeaderStyle>
              <Style TargetType="DataGridColumnHeader">
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="Foreground" Value="#00F0FF"/>
                <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
                <Setter Property="FontSize" Value="11"/>
                <Setter Property="Padding" Value="10,9"/>
                <Setter Property="BorderBrush" Value="#4400F0FF"/>
                <Setter Property="BorderThickness" Value="0,0,0,1"/>
                <Setter Property="Cursor" Value="Hand"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="DataGridColumnHeader">
                      <Grid>
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
                          <DockPanel>
                            <Path x:Name="arrow" DockPanel.Dock="Right" Fill="#FF2BD6" Margin="6,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
                            <ContentPresenter VerticalAlignment="Center"/>
                          </DockPanel>
                        </Border>
                        <Thumb x:Name="PART_LeftHeaderGripper" HorizontalAlignment="Left" Width="6" Cursor="SizeWE">
                          <Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="Transparent"/></ControlTemplate></Thumb.Template>
                        </Thumb>
                        <Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Width="6" Cursor="SizeWE">
                          <Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="Transparent"/></ControlTemplate></Thumb.Template>
                        </Thumb>
                      </Grid>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#FF2BD6"/></Trigger>
                        <Trigger Property="SortDirection" Value="Ascending">
                          <Setter TargetName="arrow" Property="Visibility" Value="Visible"/>
                          <Setter TargetName="arrow" Property="Data" Value="M0,5 L4,0 L8,5 Z"/>
                        </Trigger>
                        <Trigger Property="SortDirection" Value="Descending">
                          <Setter TargetName="arrow" Property="Visibility" Value="Visible"/>
                          <Setter TargetName="arrow" Property="Data" Value="M0,0 L8,0 L4,5 Z"/>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </DataGrid.ColumnHeaderStyle>
            <DataGrid.RowStyle>
              <Style TargetType="DataGridRow">
                <Style.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#1400F0FF"/></Trigger>
                </Style.Triggers>
              </Style>
            </DataGrid.RowStyle>
            <DataGrid.CellStyle>
              <Style TargetType="DataGridCell">
                <Setter Property="BorderThickness" Value="0"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                      <Border Background="{TemplateBinding Background}" Padding="10,0">
                        <ContentPresenter VerticalAlignment="Center"/>
                      </Border>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
                <Style.Triggers>
                  <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#33FF2BD6"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                  </Trigger>
                </Style.Triggers>
              </Style>
            </DataGrid.CellStyle>
            <DataGrid.Columns>
              <DataGridTemplateColumn Width="106" CanUserSort="False">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <Border Width="84" Height="40" Background="#05060A" BorderBrush="#4400F0FF" BorderThickness="1" ClipToBounds="True">
                      <Image Source="{Binding Image}" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
                    </Border>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="TITLE" Binding="{Binding Name}" Width="2*">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock"><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="14"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTextColumn Header="SOURCE" Binding="{Binding Launcher}" Width="100">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#00F0FF"/><Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/><Setter Property="FontSize" Value="12"/></Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTextColumn Header="STATUS" Binding="{Binding Status}" Width="130">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock">
                    <Setter Property="Foreground" Value="#39FF88"/>
                    <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
                    <Setter Property="FontSize" Value="12"/>
                    <Style.Triggers>
                      <DataTrigger Binding="{Binding StatusKind}" Value="pending"><Setter Property="Foreground" Value="#FCEE0A"/></DataTrigger>
                      <DataTrigger Binding="{Binding StatusKind}" Value="problem"><Setter Property="Foreground" Value="#FF2BD6"/></DataTrigger>
                      <DataTrigger Binding="{Binding StatusKind}" Value="busy"><Setter Property="Foreground" Value="#00F0FF"/></DataTrigger>
                    </Style.Triggers>
                  </Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTextColumn Header="AUTO-UPDATE" Binding="{Binding UpdatePolicy}" Width="120">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock">
                    <Setter Property="Foreground" Value="#6E7A91"/>
                    <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
                    <Setter Property="FontSize" Value="12"/>
                    <Style.Triggers>
                      <DataTrigger Binding="{Binding UpdatePolicyCode}" Value="2"><Setter Property="Foreground" Value="#39FF88"/></DataTrigger>
                      <DataTrigger Binding="{Binding UpdatePolicyCode}" Value="0"><Setter Property="Foreground" Value="#FCEE0A"/></DataTrigger>
                      <DataTrigger Binding="{Binding UpdatePolicyCode}" Value="1"><Setter Property="Foreground" Value="#FF2BD6"/></DataTrigger>
                    </Style.Triggers>
                  </Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTextColumn Header="SIZE" Binding="{Binding Size}" SortMemberPath="SizeBytes" Width="90">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock"><Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/><Setter Property="FontSize" Value="12"/></Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTextColumn Header="PATH" Binding="{Binding InstallPath}" Width="3*">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#5A6579"/><Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/><Setter Property="FontSize" Value="11"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
            </DataGrid.Columns>
          </DataGrid>
        </ContentControl>

        <!-- Bottom actions -->
        <DockPanel Grid.Row="4" Grid.Column="0" Margin="0,14,0,0">
          <Button x:Name="Play" Style="{StaticResource Primary}" Content="&#x25B6;  LAUNCH" Width="120" IsEnabled="False"/>
          <Button x:Name="OpenFolder" Content="OPEN FOLDER" Margin="10,0,0,0" IsEnabled="False"/>
          <Button x:Name="OpenLauncher" Style="{StaticResource Hot}" Content="OPEN LAUNCHER" Margin="10,0,0,0" IsEnabled="False"/>
          <TextBlock x:Name="StatusText" Foreground="#6E7A91" FontFamily="{StaticResource Mono}" FontSize="12"
                     VerticalAlignment="Center" HorizontalAlignment="Right"/>
        </DockPanel>

        <!-- Right panel -->
        <ContentControl Grid.Row="2" Grid.RowSpan="3" Grid.Column="1" Style="{StaticResource Frame}" Padding="18" Margin="16,0,0,0">
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel>
              <TextBlock Text="// LAUNCHERS" Style="{StaticResource Section}"/>
              <TextBlock Text="Ticked = included in the update window" Foreground="#6E7A91" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,6"/>
              <ItemsControl x:Name="LauncherList">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border BorderBrush="#1500F0FF" BorderThickness="0,0,0,1" Padding="0,7">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <CheckBox IsChecked="{Binding Enabled, Mode=OneWay}" Tag="{Binding Name}" IsEnabled="{Binding Found}" VerticalAlignment="Top" Margin="0,4,0,0"/>
                        <StackPanel Grid.Column="1" Margin="4,0">
                          <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="14"/>
                          <TextBlock Text="{Binding Detail}" Foreground="#6E7A91" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextWrapping="Wrap"/>
                        </StackPanel>
                        <Button Grid.Column="2" Content="OPEN" Tag="{Binding Name}" Padding="12,3" FontSize="11" IsEnabled="{Binding Found}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                      </Grid>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>

              <TextBlock Text="// STEAM AUTO-UPDATE" Style="{StaticResource Section}" Margin="0,22,0,8"/>
              <TextBlock Foreground="#6E7A91" FontSize="12" TextWrapping="Wrap"
                         Text="Steam's global setting lets it postpone updates for games you rarely play. Set every game to download updates immediately instead. Steam is closed briefly while this is applied."/>
              <TextBlock x:Name="SteamPolicySummary" Foreground="#D8E1F0" FontFamily="Cascadia Mono, Consolas" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap"/>
              <Button x:Name="SteamAllNow" Style="{StaticResource Primary}" Content="SET ALL TO IMMEDIATELY" Margin="0,10,0,0"/>
              <Button x:Name="SteamRevert" Style="{StaticResource Hot}" Content="REVERT ALL TO STEAM DECIDES" Margin="0,8,0,0"/>
              <CheckBox x:Name="SteamEnforce" Margin="0,10,0,0"><TextBlock Text="Re-apply nightly (catches new installs)" TextWrapping="Wrap"/></CheckBox>

              <TextBlock Text="// UPDATE WINDOW" Style="{StaticResource Section}" Margin="0,22,0,8"/>
              <TextBlock Foreground="#6E7A91" FontSize="12" TextWrapping="Wrap"
                         Text="Boots each ticked launcher, waits for its disk and network traffic to flatline, then optionally shuts it down. Turn on auto-update inside each launcher."/>
              <Grid Margin="0,12,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <TextBlock Text="Warm-up before checking (min)" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,8,0"/>
                <TextBox x:Name="Warmup" Grid.Column="1" Margin="0,3" HorizontalContentAlignment="Center"/>
                <TextBlock Grid.Row="1" Text="Done when quiet for (min)" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,8,0"/>
                <TextBox x:Name="Idle" Grid.Row="1" Grid.Column="1" Margin="0,3" HorizontalContentAlignment="Center"/>
                <TextBlock Grid.Row="2" Text="Give up after (min)" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,8,0"/>
                <TextBox x:Name="MaxMin" Grid.Row="2" Grid.Column="1" Margin="0,3" HorizontalContentAlignment="Center"/>
              </Grid>
              <CheckBox x:Name="CloseAfter" Margin="0,12,0,0"><TextBlock Text="Close launchers afterwards (only ones it opened)" TextWrapping="Wrap"/></CheckBox>
              <Button x:Name="RunNow" Style="{StaticResource Primary}" Content="&#x26A1;  RUN UPDATE WINDOW" Margin="0,14,0,0"/>

              <WrapPanel Orientation="Horizontal" Margin="0,14,0,0">
                <TextBlock Text="Nightly at" VerticalAlignment="Center"/>
                <TextBox x:Name="SchedTime" Width="64" Margin="10,0" Text="03:30" HorizontalContentAlignment="Center"/>
                <Button x:Name="Schedule" Content="ARM"/>
                <Button x:Name="Unschedule" Style="{StaticResource Hot}" Content="DISARM" Margin="8,0,0,0"/>
              </WrapPanel>
              <TextBlock x:Name="SchedStatus" Foreground="#6E7A91" FontFamily="Cascadia Mono, Consolas" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap"/>

              <TextBlock Text="// LOG" Style="{StaticResource Section}" Margin="0,22,0,8"/>
              <TextBox x:Name="LogBox" IsReadOnly="True" Height="260" FontSize="11" Foreground="#39FF88"
                       TextWrapping="Wrap" VerticalContentAlignment="Top"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
            </StackPanel>
          </ScrollViewer>
        </ContentControl>
      </Grid>

      <!-- CRT scanlines -->
      <Rectangle IsHitTestVisible="False" Opacity="0.22">
        <Rectangle.Fill>
          <DrawingBrush TileMode="Tile" Viewport="0,0,4,4" ViewportUnits="Absolute">
            <DrawingBrush.Drawing>
              <DrawingGroup>
                <GeometryDrawing Brush="Transparent"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,4,4"/></GeometryDrawing.Geometry></GeometryDrawing>
                <GeometryDrawing Brush="#000000"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,4,1"/></GeometryDrawing.Geometry></GeometryDrawing>
              </DrawingGroup>
            </DrawingBrush.Drawing>
          </DrawingBrush>
        </Rectangle.Fill>
      </Rectangle>
    </Grid>
  </Border>
</Window>
'@

function Get-GameImage($Game) {
    # Cover art first; if it is missing or fails to load, fall back to the game's exe or icon file.
    if (Get-SafeFile $Game.ImagePath @('.jpg', '.png')) {
        try {
            # Read into memory with full sharing: Steam keeps its cache files open while it runs,
            # which makes a normal open fail.
            $fs = [System.IO.File]::Open($Game.ImagePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                         [System.IO.FileShare]'ReadWrite, Delete')
            try {
                $ms = New-Object System.IO.MemoryStream
                $fs.CopyTo($ms)
            } finally { $fs.Dispose() }
            $ms.Position = 0
            $bi = [System.Windows.Media.Imaging.BitmapImage]::new()   # ::new, not New-Object: WPF can't bind PowerShell-wrapped objects
            $bi.BeginInit()
            $bi.StreamSource = $ms
            $bi.DecodePixelWidth = 200
            $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.EndInit()
            $bi.Freeze()
            $ms.Dispose()
            if ($bi.PixelWidth -gt 0) { return $bi }
            Write-Log "Cover art for $($Game.Name) decoded as an empty image"
        } catch { Write-Log "Couldn't load cover art for $($Game.Name): $($_.Exception.Message)" }
    }
    if (-not $Game.IconPath -and $Game.InstallPath) {
        # No art and no icon from the launcher: fall back to the game's own exe (looked up only when needed).
        $Game.IconPath = Find-GameExe $Game.InstallPath
    }
    if (Get-SafeFile $Game.IconPath @('.exe', '.ico')) {
        try {
            $ico = if ($Game.IconPath -like '*.ico') { New-Object System.Drawing.Icon($Game.IconPath, 64, 64) }
                   else { [System.Drawing.Icon]::ExtractAssociatedIcon($Game.IconPath) }
            if ($ico) {
                $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                    $ico.Handle, [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                $src.Freeze()
                $ico.Dispose()
                $Game.ImageStretch = 'Uniform'
                return $src
            }
        } catch { Write-Log "Couldn't load icon for $($Game.Name): $($_.Exception.Message)" }
    }
    $null
}

function Start-Game($Game) {
    if (-not $Game) { return }
    try {
        if ($Game.LaunchUri -and (Test-SafeLaunchUri $Game.LaunchUri)) { Start-Process $Game.LaunchUri; return }
        if ($Game.LaunchExe) {
            $exe = Get-SafeFile $Game.LaunchExe @('.exe')
            $isLauncher = $exe -and (Test-TrustedLauncherExe $exe $Game.Launcher)
            $inGameDir  = $exe -and $Game.InstallPath -and $exe.StartsWith($Game.InstallPath + '\', [System.StringComparison]::OrdinalIgnoreCase)
            if ($isLauncher -and $Game.LaunchArgs) { Start-Process -FilePath $exe -ArgumentList $Game.LaunchArgs; return }
            if ($inGameDir) { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe); return }
            Write-Log "Blocked launch of $($Game.Name): '$($Game.LaunchExe)' is neither a signed launcher nor inside the game folder"
        }
        Open-Launcher $Game.Launcher
    } catch {
        [System.Windows.MessageBox]::Show("Couldn't start $($Game.Name):`n$($_.Exception.Message)", 'PATCHD') | Out-Null
    }
}

function Open-Launcher([string]$Name) {
    $l = $script:Launchers | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($l -and $l.Exe) { Start-Process -FilePath $l.Exe -WorkingDirectory (Split-Path $l.Exe) }
}

function Update-GridView {
    $ui = $script:ui
    $q = $ui.Search.Text.Trim()
    $items = $script:Games
    if ($script:Filter -ne 'All') { $items = @($items | Where-Object { $_.Launcher -eq $script:Filter }) }
    if ($q) { $items = @($items | Where-Object { $_.Name.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
    $ui.Grid.ItemsSource = @($items)
    $ui.StatusText.Text = '[ {0} / {1} SHOWN ]' -f @($items).Count, @($script:Games).Count
}

function Import-Library {
    $ui = $script:ui
    $ui.Summary.Text = '> SCANNING LAUNCHERS...'
    $script:Window.Dispatcher.Invoke([action] { }, [System.Windows.Threading.DispatcherPriority]::Render)

    $script:Games = @(Get-AllGames)
    foreach ($g in $script:Games) {
        $img = Get-GameImage $g
        $g.Image = if ($img) { $img.psobject.BaseObject } else { $null }   # hand WPF the raw image, never a wrapper
    }
    $script:Launchers = @(Get-LauncherInfo)

    $rows = foreach ($l in $script:Launchers) {
        $n = @($script:Games | Where-Object { $_.Launcher -eq $l.Name }).Count
        [pscustomobject]@{
            Name    = $l.Name
            Found   = [bool]$l.Exe
            Enabled = ($script:Settings.EnabledLaunchers -contains $l.Name)
            BaseDetail = if ($l.Blocked) { 'BLOCKED: SIGNATURE CHECK FAILED' } elseif (-not $l.Exe) { 'NOT DETECTED' } elseif ($n -eq 1) { '1 GAME' } else { "$n GAMES" }
            Detail  = ''
        }
    }
    foreach ($r in $rows) { $r.Detail = $r.BaseDetail }
    $script:LauncherRows = @($rows)
    $ui.LauncherList.ItemsSource = $script:LauncherRows

    $ui.Chips.Children.Clear()
    $withGames = @($script:Launchers | Where-Object { $n = $_.Name; @($script:Games | Where-Object { $_.Launcher -eq $n }).Count -gt 0 })
    foreach ($name in @('All') + @($withGames | ForEach-Object Name)) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Content = $name
        $rb.GroupName = 'LauncherFilter'
        $rb.Style = $script:Window.FindResource('Chip')
        if ($name -eq $script:Filter) { $rb.IsChecked = $true }
        $rb.Add_Checked({ $script:Filter = [string]$this.Content; Update-GridView })
        [void]$ui.Chips.Children.Add($rb)
    }
    if (-not ($withGames | Where-Object { $_.Name -eq $script:Filter })) {
        $script:Filter = 'All'
        $ui.Chips.Children[0].IsChecked = $true
    }

    $pending = @($script:Games | Where-Object { $_.Status -in 'Update queued', 'Updating', 'Update paused', 'Incomplete' }).Count
    $ui.Summary.Text = '> {0} GAMES // {1} LAUNCHERS ONLINE{2}' -f @($script:Games).Count, $withGames.Count,
        $(if ($pending) { " // $pending NEED ATTENTION" } else { '' })
    $steamGames = @($script:Games | Where-Object { $_.Launcher -eq 'Steam' })
    if ($steamGames.Count) {
        $now = @($steamGames | Where-Object { $_.UpdatePolicyCode -eq '2' }).Count
        $ui.SteamPolicySummary.Text = '> {0} / {1} STEAM GAMES SET TO IMMEDIATELY' -f $now, $steamGames.Count
    } else {
        $ui.SteamPolicySummary.Text = '> NO STEAM GAMES FOUND'
    }
    Update-GridView
}

function Invoke-SteamPolicyChange([int]$Value) {
    $label = $script:SteamPolicyNames[[string]$Value]
    $todo = @($script:Games | Where-Object { $_.Launcher -eq 'Steam' -and $_.UpdatePolicyCode -ne [string]$Value })
    if (-not $todo.Count) {
        [System.Windows.MessageBox]::Show("All Steam games are already set to '$label'.", 'PATCHD') | Out-Null
        return
    }
    $steamL = $script:Launchers | Where-Object { $_.Name -eq 'Steam' } | Select-Object -First 1
    $wasRunning = [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
    if ($wasRunning) {
        $answer = [System.Windows.MessageBox]::Show(
            "Steam has to close while $($todo.Count) game setting(s) are changed. It will reopen afterwards.`n`nClose Steam now?",
            'PATCHD', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
        if (-not $steamL -or -not $steamL.Exe) {
            [System.Windows.MessageBox]::Show("Couldn't find a verified steam.exe to close Steam with. Close it yourself and try again.", 'PATCHD') | Out-Null
            return
        }
        $script:ui.StatusText.Text = '[ CLOSING STEAM... ]'
        $script:ui.SteamAllNow.IsEnabled = $false
        $script:ui.SteamRevert.IsEnabled = $false
        $pump = { $script:Window.Dispatcher.Invoke([action] { }, [System.Windows.Threading.DispatcherPriority]::Background) }
        try { Stop-Launcher $steamL -OnWait $pump }
        finally { $script:ui.SteamAllNow.IsEnabled = $true; $script:ui.SteamRevert.IsEnabled = $true }
        if (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) {
            [System.Windows.MessageBox]::Show("Steam didn't close in time, so nothing was changed.", 'PATCHD') | Out-Null
            return
        }
    }
    $n = 0
    try { $n = Set-SteamAutoUpdate $todo $Value }
    catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'PATCHD') | Out-Null }
    if ($wasRunning -and $steamL.Exe) { Start-Launcher $steamL }
    Import-Library
    $script:ui.StatusText.Text = "[ $n STEAM GAME(S) SET TO $($label.ToUpper()) ]"
}

function Save-UiSettings {
    $s = $script:Settings
    $n = 0
    if ([int]::TryParse($script:ui.Warmup.Text, [ref]$n) -and $n -ge 0) { $s.WarmupMinutes = $n }
    if ([int]::TryParse($script:ui.Idle.Text,   [ref]$n) -and $n -ge 1) { $s.IdleMinutes = $n }
    if ([int]::TryParse($script:ui.MaxMin.Text, [ref]$n) -and $n -ge 5) { $s.MaxMinutes = $n }
    $s.CloseLaunchersAfter = [bool]$script:ui.CloseAfter.IsChecked
    $s.SteamForceImmediate = [bool]$script:ui.SteamEnforce.IsChecked
    Save-Settings $s
    $script:ui.Warmup.Text = [string]$s.WarmupMinutes
    $script:ui.Idle.Text   = [string]$s.IdleMinutes
    $script:ui.MaxMin.Text = [string]$s.MaxMinutes
}

function Test-UpdateWindowRunning {
    # Cheap enough for the refresh timer: just checks whether a running update window holds its lock.
    $lock = $null
    if ([System.Threading.Mutex]::TryOpenExisting($script:UpdateLock, [ref]$lock)) { $lock.Dispose(); return $true }
    $false
}

function Update-RunButton {
    if (-not $script:ScriptPath) { return }
    $running = Test-UpdateWindowRunning
    if ($running -eq $script:RunButtonState) { return }   # restyling every tick makes the window stutter
    $script:RunButtonState = $running
    if ($running) {
        $script:ui.RunNow.Content = [string][char]0x25A0 + '  STOP UPDATE WINDOW'
        $script:ui.RunNow.Style = $script:Window.FindResource('Hot')
    } else {
        $script:ui.RunNow.Content = [string][char]0x26A1 + '  RUN UPDATE WINDOW'
        $script:ui.RunNow.Style = $script:Window.FindResource('Primary')
    }
}

function Update-LauncherActivity {
    # Shows what a running update window reports for each launcher, e.g. "1 GAME // DOWNLOADING 12.4 MB/S".
    if (-not $script:LauncherRows) { return }
    $live = @{}
    if ($script:RunButtonState -and (Test-Path -LiteralPath $script:StatusFile)) {
        try {
            $data = Get-Content -LiteralPath $script:StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($x in @($data.Launchers)) {
                $live[[string]$x.Name] = switch ([string]$x.State) {
                    'starting'    { 'WARMING UP' }
                    'downloading' { 'DOWNLOADING {0:N1} MB/S' -f ([double]$x.KBps / 1024) }
                    'pending'     { 'UPDATES PENDING' }
                    'quiet'       { 'QUIET' }
                    'done'        { 'DONE' }
                    'closed'      { 'CLOSED' }
                    default       { '' }
                }
            }
        } catch { }
    }
    $changed = $false
    foreach ($r in $script:LauncherRows) {
        $text = if ($live[$r.Name]) { "$($r.BaseDetail) // $($live[$r.Name])" } else { $r.BaseDetail }
        if ($text -ne $r.Detail) { $r.Detail = $text; $changed = $true }
    }
    if ($changed) { $script:ui.LauncherList.Items.Refresh() }
}

function Update-SteamStatuses {
    # Re-reads Steam's manifests (small files) so "Updating 42%" moves while Steam downloads.
    $steamGames = @($script:Games | Where-Object { $_.Launcher -eq 'Steam' })
    if (-not $steamGames.Count) { return }
    $fresh = @{}
    try { foreach ($g in @(Get-SteamGames -StatusOnly)) { $fresh[$g.Id] = $g.Status } } catch { return }
    $changed = $false
    foreach ($g in $steamGames) {
        if ($fresh.ContainsKey($g.Id) -and $fresh[$g.Id] -ne $g.Status) {
            $g.Status = $fresh[$g.Id]
            $g.StatusKind = Get-StatusKind $g.Status
            $changed = $true
        }
    }
    if ($changed) { $script:ui.Grid.Items.Refresh() }
}

function Update-LogView {
    if (-not (Test-Path -LiteralPath $script:LogFile)) { $script:ui.LogBox.Text = '> awaiting first update run_'; return }
    $stamp = (Get-Item -LiteralPath $script:LogFile).LastWriteTimeUtc
    if ($stamp -eq $script:LogStamp) { return }
    $script:LogStamp = $stamp
    $script:ui.LogBox.Text = (Get-Content -LiteralPath $script:LogFile -Tail 150 -Encoding UTF8) -join "`r`n"
    $script:ui.LogBox.ScrollToEnd()
}

function Show-PATCHD {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

    [xml]$xml = $script:Xaml
    $script:Window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    $script:ui = @{}
    foreach ($n in 'Summary', 'Refresh', 'Search', 'SearchHint', 'Chips', 'Grid', 'Play', 'OpenFolder', 'OpenLauncher',
                   'StatusText', 'VersionBadge', 'LauncherList', 'SteamPolicySummary', 'SteamAllNow', 'SteamRevert', 'SteamEnforce', 'Root', 'BtnMin', 'BtnMax', 'BtnClose', 'Warmup', 'Idle', 'MaxMin', 'CloseAfter', 'RunNow', 'SchedTime',
                   'Schedule', 'Unschedule', 'SchedStatus', 'LogBox') {
        $script:ui[$n] = $script:Window.FindName($n)
    }
    $ui = $script:ui
    $script:Window.Title = "PATCHD $script:Version"
    $ui.VersionBadge.Text = "v$script:Version"
    # Window and taskbar icon, from PATCHD.ico next to the script (installed copies have it).
    if ($script:ScriptPath) {
        $icoPath = Get-SafeFile (Join-Path (Split-Path $script:ScriptPath) 'PATCHD.ico') @('.ico')
        if ($icoPath) {
            try { $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]$icoPath) } catch { }
        }
    }
    $script:Settings = Get-Settings
    $script:Filter = 'All'
    $script:LogStamp = $null
    $script:RunButtonState = $null

    $ui.Warmup.Text = [string]$script:Settings.WarmupMinutes
    $ui.Idle.Text   = [string]$script:Settings.IdleMinutes
    $ui.MaxMin.Text = [string]$script:Settings.MaxMinutes
    $ui.CloseAfter.IsChecked = [bool]$script:Settings.CloseLaunchersAfter
    $ui.SteamEnforce.IsChecked = [bool]$script:Settings.SteamForceImmediate
    $ui.SchedStatus.Text = Get-ScheduleText

    if (-not $script:ScriptPath) {
        $ui.RunNow.IsEnabled = $false; $ui.Schedule.IsEnabled = $false
        $ui.SchedStatus.Text = 'Run PATCHD from its .ps1 file to enable updates and scheduling.'
    }

    # Custom title bar (window has no standard frame)
    $ui.BtnMin.Add_Click({ $script:Window.WindowState = 'Minimized' })
    $ui.BtnMax.Add_Click({
        $script:Window.WindowState = if ($script:Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
    })
    $ui.BtnClose.Add_Click({ $script:Window.Close() })
    $script:Window.Add_StateChanged({
        # A frameless maximised window overhangs the screen edge slightly; pad it back in.
        if ($script:Window.WindowState -eq 'Maximized') {
            $script:ui.Root.Margin = New-Object System.Windows.Thickness(7)
            $script:ui.BtnMax.Content = [string][char]0xE923
        } else {
            $script:ui.Root.Margin = New-Object System.Windows.Thickness(0)
            $script:ui.BtnMax.Content = [string][char]0xE922
        }
    })

    # Search
    $ui.Search.Add_TextChanged({
        $script:ui.SearchHint.Visibility = if ($script:ui.Search.Text) { 'Collapsed' } else { 'Visible' }
        Update-GridView
    })

    # Selection-driven buttons
    $ui.Grid.Add_SelectionChanged({
        $has = $null -ne $script:ui.Grid.SelectedItem
        $script:ui.Play.IsEnabled = $has; $script:ui.OpenFolder.IsEnabled = $has; $script:ui.OpenLauncher.IsEnabled = $has
    })
    $ui.Grid.Add_MouseDoubleClick({ Start-Game $script:ui.Grid.SelectedItem })
    $ui.Play.Add_Click({ Start-Game $script:ui.Grid.SelectedItem })
    $ui.OpenFolder.Add_Click({
        $g = $script:ui.Grid.SelectedItem
        $dir = if ($g) { Get-SafeDir $g.InstallPath } else { $null }
        if ($dir) {
            Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -ArgumentList "`"$dir`""
        }
    })
    $ui.OpenLauncher.Add_Click({ if ($script:ui.Grid.SelectedItem) { Open-Launcher $script:ui.Grid.SelectedItem.Launcher } })
    $ui.Refresh.Add_Click({ Import-Library })

    # Launcher list: tick boxes (include in update window) and Open buttons
    $ui.LauncherList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($sender, $e)
        $src = $e.OriginalSource
        if ($src -is [System.Windows.Controls.CheckBox]) {
            $name = [string]$src.Tag
            $list = New-Object System.Collections.Generic.List[string]
            foreach ($x in $script:Settings.EnabledLaunchers) { if ($x -ne $name) { $list.Add($x) } }
            if ($src.IsChecked) { $list.Add($name) }
            foreach ($r in $script:LauncherRows) { if ($r.Name -eq $name) { $r.Enabled = [bool]$src.IsChecked } }
            $script:Settings.EnabledLaunchers = $list.ToArray()
            Save-Settings $script:Settings
        } elseif ($src -is [System.Windows.Controls.Button]) {
            Open-Launcher ([string]$src.Tag)
        }
    })

    # Update window: runs in a separate PowerShell process so the UI stays responsive
    $ui.RunNow.Add_Click({
        $running = Get-UpdateWindowProcess
        if ($running) {
            $since = if ($running.CreationDate) { ' since ' + ([datetime]$running.CreationDate).ToString('HH:mm') } else { '' }
            $answer = [System.Windows.MessageBox]::Show(
                "An update window has been running$since.`n`nStop it now? Launchers it started are left open.",
                'PATCHD', 'YesNo', 'Question')
            if ($answer -eq 'Yes') {
                if ($running.ProcessId) {
                    Stop-Process -Id $running.ProcessId -Force -ErrorAction SilentlyContinue
                    Write-Log 'Update window stopped by user.'
                } else {
                    [System.Windows.MessageBox]::Show("Couldn't find the update window's process. It will stop by itself when its time limit is reached.", 'PATCHD') | Out-Null
                }
            }
            $script:RunButtonState = $null
            Update-RunButton
            return
        }
        Save-UiSettings
        $argList = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', "`"$($script:ScriptPath)`"", '-UpdateAll')
        Start-Process -FilePath $script:PowerShellExe -ArgumentList $argList -WindowStyle Minimized
        $script:ui.StatusText.Text = '[ UPDATE WINDOW STARTED - SEE LOG ]'
        $script:ui.RunNow.Content = 'STARTING...'
        $script:RunButtonState = $null   # let the next refresh set the button properly
    })

    $ui.Schedule.Add_Click({
        Save-UiSettings
        $t = [datetime]::MinValue
        $formats = [string[]]@('HH:mm', 'H:mm')
        if (-not [datetime]::TryParseExact($script:ui.SchedTime.Text.Trim(), $formats, $null, 'None', [ref]$t)) {
            [System.Windows.MessageBox]::Show('Enter a time like 03:30.', 'PATCHD') | Out-Null
            return
        }
        try {
            Register-UpdateTask -At $t
            $script:ui.SchedStatus.Text = Get-ScheduleText
        } catch {
            [System.Windows.MessageBox]::Show("Couldn't create the scheduled task:`n$($_.Exception.Message)", 'PATCHD') | Out-Null
        }
    })
    $ui.Unschedule.Add_Click({
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        $script:ui.SchedStatus.Text = Get-ScheduleText
    })

    # Steam per-game auto-update
    $ui.SteamAllNow.Add_Click({ Invoke-SteamPolicyChange 2 })
    $ui.SteamRevert.Add_Click({ Invoke-SteamPolicyChange 0 })
    $ui.SteamEnforce.Add_Click({ Save-UiSettings })

    # Live log
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(3)
    $script:TickCount = 0
    $timer.Add_Tick({
        $script:TickCount++
        Update-LogView
        Update-RunButton
        Update-LauncherActivity
        if ($script:TickCount % 2 -eq 0) { Update-SteamStatuses }   # every 6 seconds
    })
    $timer.Start()

    $script:Window.Add_ContentRendered({ Import-Library; Update-LogView; Update-RunButton })
    $script:Window.Add_Closed({ $timer.Stop() })
    [void]$script:Window.ShowDialog()
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($UpdateAll) {
    Invoke-UpdateWindow
    return
}

if ($ListOnly) {
    Get-AllGames | Format-Table Name, Launcher, Status, Size,
        @{ n = 'Art'; e = { if ($_.ImagePath) { Split-Path $_.ImagePath -Leaf } elseif ($_.IconPath) { 'icon: ' + (Split-Path $_.IconPath -Leaf) } else { '-' } } },
        @{ n = 'Auto-update'; e = { $_.UpdatePolicy } }, InstallPath -AutoSize
    Get-LauncherInfo | Format-Table Name, Exe -AutoSize
    return
}

Show-PATCHD
