# Security

## Reporting a vulnerability

Please report security issues privately using GitHub's **Report a vulnerability** button on the repository's **Security** tab, not in a public issue. Include the PATCHD version, Windows version and steps to reproduce.

## Security model

PATCHD assumes the attacker is **another program running as you**, without administrator rights: a malicious mod, a compromised download, a rogue browser extension. Such a program can edit your user registry, Steam's library files and some launcher data under `%ProgramData%`. PATCHD's job is to avoid becoming a tool that such a program can use to leak credentials or run code on a schedule.

It does not try to defend against an attacker who already has administrator rights.

### What it uses

- Windows PowerShell 5.1, WPF and the ScheduledTasks module, all built into Windows.
- No third-party modules, no downloads, no compiled or embedded code (`Add-Type`), no `Invoke-Expression`.
- No network requests of its own. (Windows may check certificate revocation online when verifying launcher signatures.)
- PATCHD itself runs without administrator rights, and the scheduled task runs as you with standard privileges. Only the installer needs administrator approval, once.

### What it reads

Launcher manifests, launcher registry keys, Windows uninstall entries, and cover art and icons from local files. All of this is treated as untrusted input.

### What the installer does

- Takes every system location (Program Files, System32, the Start menu) from Windows itself, never from environment variables, which a program running as you could override to redirect an administrator-run installer. It also refuses to install into a junction or symbolic link.

- Runs once with administrator rights, which you approve. `Install.cmd` uses `-ExecutionPolicy Bypass` for that single run so a freshly downloaded copy can start; nothing else does.
- Copies three files into `C:\Program Files\PATCHD` and resets the folder to inherit Program Files' permissions: administrators and SYSTEM can change it, everyone else can only read it.
- Unblocks the installed files, so PATCHD itself runs under `RemoteSigned`.
- Adds Start menu (and optionally desktop) shortcuts and a Settings → Apps entry, and re-points an existing *PATCHD nightly updates* task.
- Uninstalling removes all of the above. It never touches launchers, games or Steam settings.

### What it writes

| Location | When |
|---|---|
| `%LOCALAPPDATA%\PATCHD\` | Always: settings, log, Steam manifest backups |
| Steam `appmanifest_<id>.acf` files — only the `AutoUpdateBehavior` line | Only when you use the Steam auto-update buttons or enable *Re-apply nightly*; only while Steam is closed; the original is backed up first |
| A scheduled task under your account | Only when you press ARM |

### What it starts and stops

- Launcher executables, only if they carry a valid Authenticode signature whose organisation (`O=`) **exactly** matches a publisher declared in that launcher's registration, for example `Valve Corp.` or `Blizzard Entertainment, Inc.`. Lookalike names such as "Valve Corp. Ltd" don't pass.
- Game launch links, only for URL schemes a registered launcher declares (currently `steam://`, `com.epicgames.launcher://`, `uplay://` and `origin2://`), with a strict character allowlist. Registration refuses web, file and shell schemes, so a launcher definition can't turn a launch link into a web or file open.
- Game executables directly, only when they sit inside that game's install folder.
- Closing launchers only affects processes whose executable is signed by that launcher's publisher, never a process that merely shares its name.

### Input hardening

- **Local paths only.** UNC paths, mapped network drives, device paths, URLs, alternate data streams and PowerShell provider paths (for example `HKCU:\`) are rejected before any file access. This prevents a planted `\\server\share` path from making Windows send your NTLM credentials to a remote server.
- **Folders must be folders.** *Open folder* only opens real directories, because Explorer runs files it is given.
- **No path traversal** in Steam install-folder names.
- **Machine-wide URL handlers only.** Launcher locations are never taken from per-user `HKEY_CLASSES_ROOT` overrides.
- **Typed, range-checked settings.** `settings.json` is validated on every load.
- **Log sanitising.** Control characters are stripped so game names can't forge log lines.
- **Size limits** on manifest files; images restricted to local `.jpg`/`.png`, icons to local `.exe`/`.ico`.

## Launcher definitions

Each launcher is declared once with `Register-Launcher`, which validates the definition: required fields, a plain name and publisher, script blocks where code is expected, and permitted URL schemes only. Signature checks, the launch-link allowlist and the process-closing filter are applied to every registered launcher automatically, so a new launcher can't skip them.

## Known limitations

- **The script file itself.** The scheduled task runs whatever `PATCHD.ps1` is in the install folder. The installer puts it in `C:\Program Files\PATCHD`, which ordinary programs can't write to; if you copy PATCHD somewhere else by hand, keep it in a folder only administrators can change. For stronger assurance, sign the scripts with your own code-signing certificate and change the task and shortcut to use `-ExecutionPolicy AllSigned`.
- **Hidden PowerShell window.** The Start menu shortcut starts PowerShell with `-WindowStyle Hidden` so only the PATCHD window appears. Some security tools flag hidden PowerShell in general; the nightly task deliberately runs minimised instead so its activity stays visible.
- **Installing from a folder you can write to.** Between double-clicking `Install.cmd` and approving the administrator prompt, a program already running as you could swap the files in the extracted folder. This applies to most installers run from Downloads. Check the release hashes before installing and extract straight from the zip.
- **Scheduling is refused from unprotected folders.** PATCHD won't set up the nightly task if its own folder can be changed by ordinary programs, or while it is running as administrator.
- **Execution policy is not a security boundary.** `RemoteSigned` prevents accidental runs, not deliberate ones.
- **Launchers' own update channels** are outside PATCHD's control.
- **Wake timers.** The scheduled task can wake the PC; disable this in Task Scheduler if unwanted.

## Verifying downloads

Each release includes `SHA256SUMS.txt` with hashes for the release zip and every file in it. Check before installing:

```powershell
Get-FileHash .\PATCHD-<version>.zip -Algorithm SHA256
```

Only download PATCHD from this repository's Releases page.
