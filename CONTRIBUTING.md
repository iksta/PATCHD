# Contributing to PATCHD

Thanks for helping. The most useful contributions are **support for launchers the maintainer doesn't use**, and **bug reports from setups that differ from the maintainer's**. Only someone with a launcher installed can test it.

- **Found a bug?** Open a [bug report](../../issues/new?template=bug_report.yml).
- **Want a launcher supported?** Open a [launcher request](../../issues/new?template=launcher_request.yml), or add it yourself using the guide below.
- **Found a security issue?** Don't open an issue; follow [SECURITY.md](SECURITY.md).

## Ground rules

PATCHD's promise is "only what ships with Windows". Every change must keep it:

- **Windows PowerShell 5.1 compatible.** No PowerShell 7-only syntax (`??`, `?:`, `ForEach-Object -Parallel`, `&&`).
- **No dependencies.** No modules, NuGet packages, downloaded binaries or `Add-Type` with C# source.
- **No `Invoke-Expression`**, and no building commands out of strings from launcher data.
- **No network calls.** Launchers do their own updating.
- **Read-only towards launchers.** Don't write launcher files or settings. The one exception, Steam's per-game update setting, is opt-in, backed up and only written while Steam is closed.
- **Plain ASCII in `.ps1` files.** Windows PowerShell misreads UTF-8 without a BOM.
- **Treat all launcher data as untrusted** (see [Security rules for scanners](#security-rules-for-scanners)).
- **No personal data** in commits, issues or screenshots: no usernames, PC names, personal paths or game libraries you'd rather not share.

## Adding a launcher

A launcher is two things in `PATCHD.ps1`:

1. a **scanner function** that finds its installed games
2. a **`Register-Launcher` block** that describes it

Nothing else needs changing. Settings, signature checks, the launch-link allowlist, the update window, filter chips and the launcher panel all read from the registry.

### 1. Write the scanner

Add a `Get-<Launcher>Games` function next to the existing ones (search for `function Get-EpicGames`). It returns one `New-Game` object per installed game.

```powershell
function Get-ExampleGames {
    $root = 'HKLM:\SOFTWARE\WOW6432Node\Example Launcher\Games'
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
        $id = $k.PSChildName
        if ($id -notmatch '^\d{1,10}$') { continue }                          # validate IDs
        $loc = Get-SafeDir (Get-RegValue $k.PSPath 'InstallPath')             # local folders only
        if (-not $loc) { continue }
        New-Game -Name (Get-RegValue $k.PSPath 'DisplayName') -Launcher 'Example' -Id $id `
                 -InstallPath $loc -LaunchUri "examplelauncher://launch/$id" `
                 -IconPath (Find-GameExe $loc)
    }
}
```

**`New-Game` parameters**

| Parameter | Required | Meaning |
|---|---|---|
| `Name` | Yes | Game title as shown |
| `Launcher` | Yes | Your launcher's `Name` (PATCHD overwrites it anyway, so a scanner can't mislabel games) |
| `InstallPath` | Strongly advised | Game folder, from `Get-SafeDir`. Also used to de-duplicate games seen by two launchers |
| `Id` | No | Launcher's ID for the game |
| `SizeBytes` | No | Size on disk, in bytes |
| `Status` | No | `Installed` (default), `Update queued`, `Updating`, `Update paused`, `Installing` or `Incomplete`. These values are colour-coded |
| `LaunchUri` | No | Link that launches the game. Its scheme must be in your `UriSchemes` |
| `LaunchExe` / `LaunchArgs` | No | Exe to start instead of a link. Allowed only if it is your signed launcher or sits inside `InstallPath` |
| `ImagePath` | No | Local `.jpg`/`.png` cover art |
| `IconPath` | No | Local `.exe`/`.ico` to take an icon from. `Find-GameExe $InstallPath` is a good default |

If a game has no launch link or exe, **Launch** opens the launcher instead.

**Helpers you can use**

| Helper | Does |
|---|---|
| `Get-RegValue path name` | Reads a registry value, or `$null` |
| `Get-UninstallCache` | All Windows uninstall entries (`DisplayName`, `Publisher`, `InstallLocation`, `UninstallString`, `DisplayIcon`, `EstimatedSizeKB`) |
| `Get-SafeDir path` | Returns the path only if it's a real **local** folder |
| `Get-SafeFile path @('.ext')` | Returns the path only if it's a real local file with an allowed extension |
| `Find-FirstFile @(paths)` | First path that's a real local `.exe` |
| `Resolve-IconPath value` | Cleans up a `DisplayIcon` value into a usable icon path |
| `Get-ProtocolExe scheme` | The exe registered machine-wide for a URL scheme |
| `Find-GameExe folder` | Best guess at a game's main exe, for its icon |
| `Write-Log text` | Adds a line to the log |

### 2. Register it

Add a block in the `LAUNCHERS` section. Storefronts go before publisher launchers: when two launchers report the same install folder, the one registered first keeps the game.

```powershell
Register-Launcher @{
    Name           = 'Example'
    Publisher      = 'Example Software Ltd.'   # exact O= value from the signing certificate
    UriSchemes     = @('examplelauncher')
    FindExe        = {
        @("${env:ProgramFiles(x86)}\Example\ExampleLauncher.exe", (Get-ProtocolExe 'examplelauncher'))
    }
    StartArgs      = '--minimized'
    Processes      = @('ExampleLauncher', 'ExampleUpdater')
    CloseProcesses = @('ExampleLauncher')
    FindGames      = { Get-ExampleGames }
}
```

| Field | Required | Meaning |
|---|---|---|
| `Name` | Yes | Short display name. Letters, digits, spaces and `.+-` only |
| `Publisher` | Yes | The **exact** organisation (`O=`) from the launcher exe's code-signing certificate, or an array of them if the publisher signs with more than one company name. Find it with `(Get-AuthenticodeSignature "<launcher exe>").SignerCertificate.Subject` and copy the `O=` value without quotes, e.g. `O="Electronic Arts, Inc."` becomes `'Electronic Arts, Inc.'`. Anything else shows the launcher as **BLOCKED**, and it is never started |
| `FindExe` | Yes | Script block returning candidate paths for the launcher exe, best first. The first that exists, is local and passes the signature check is used |
| `FindGames` | Yes | Script block returning the launcher's games, usually `{ Get-<Launcher>Games }` |
| `Processes` | Yes | Process names (no `.exe`) whose disk and network activity counts as "updating". Include background downloaders |
| `CloseProcesses` | No | Processes to close afterwards. Defaults to `Processes`. Leave out background services |
| `StartArgs` | No | Arguments for a quiet, minimised start, if the launcher supports any |
| `UriSchemes` | No | URL schemes your games' `LaunchUri` values use. Web, file and shell schemes are refused |
| `ProcessFilter` | No | `{ param($Process) ... }` returning `$true` for processes that really belong to the launcher. Use it when a process name is generic (see Battle.net's `Agent`) |
| `GetPendingUpdates` | No | Script block returning the names of games the launcher reports as needing an update. The update window keeps waiting while any remain (see Steam) |
| `Close` | No | `{ param($Launcher) ... }` that asks the launcher to shut down cleanly, if it has a proper way (see Steam's `-shutdown`). Otherwise PATCHD closes its signed processes |

### 3. Test it

1. `-ListOnly`: your games appear with sensible names, paths and art, and your launcher has an exe in the launcher list.
2. Open PATCHD: the launcher isn't **BLOCKED**, its chip filters correctly, and **Launch**, **Open folder** and **Open launcher** work.
3. **Run update window** with only your launcher ticked. It should start, be detected as busy while updating, finish when quiet and, with *Close launchers afterwards* on, close cleanly.
4. Add a row to the *Supported launchers* table in `README.md`, and to *Launcher limits* if the launcher skips some games (for example, only updating recently played ones).

### Security rules for scanners

Launcher files and registry keys can be edited by any program running as the user, so scanners must:

- pass every path through `Get-SafeDir`, `Get-SafeFile` or `Find-FirstFile`, never `Test-Path` alone
- validate IDs with a strict pattern before putting them in a link or argument
- skip files over a sensible size (see the 1 MB checks in existing scanners)
- read text files with `-Encoding UTF8`
- never execute, dot-source or `Invoke-Expression` anything they read

## Pull requests

- One change per pull request, please.
- Say what you tested and on which Windows version.
- Keep the existing style: 4-space indents, full cmdlet names, comments that explain *why*.
- If you change behaviour, update `README.md` (and `SECURITY.md` if it affects what PATCHD reads, writes, starts or stops).

## Releases (maintainer)

Bump `$script:Version` in `PATCHD.ps1`, run `build\New-Release.ps1`, then attach `dist\PATCHD-<version>.zip` and `dist\SHA256SUMS.txt` to a GitHub release.
