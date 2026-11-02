# PATCHD

One window for every PC game you have installed, across Steam, Epic, EA app, Ubisoft Connect, Battle.net and Wargaming Game Center — plus a hands-off nightly "update window" so games are patched before you sit down to play.

PATCHD is a PowerShell script with a WPF interface and a one-click installer. It uses only what ships with Windows 10 and 11: no runtimes, no modules, no downloads, no telemetry. Admin approval is needed once, to install.

> **Status: beta.** It has only been tested on a single PC so far. Please open an issue if a launcher or game is missed.

---

## Features

- **Unified library.** Lists installed games from every supported launcher in one searchable, filterable list, with cover art from Steam's local cache and icons for everything else. Games bought on one store and installed through another (for example a Ubisoft game on Steam) appear once.
- **Launch, open folder, open launcher** for any game.
- **Steam auto-update fix.** Steam's global auto-update setting lets it postpone updates for games you rarely play. The per-game "Immediately download updates" option fixes that, but Steam only lets you set it one game at a time. PATCHD sets it for every Steam game in one click, and can re-apply it nightly so new installs are covered too.
- **Update window.** Starts each launcher you choose, waits until its disk and network activity goes quiet, then optionally closes it again. Run it on demand or schedule it nightly; it can wake the PC to do so.
- **Live log** of every update run.

## Supported launchers

| Launcher | How games are found | Update status shown | "Launch" button |
|---|---|---|---|
| Steam | `appmanifest_*.acf` in every Steam library | Yes, live per game (queued / updating with % / paused) | Launches the game |
| Epic Games | Launcher manifests in `%ProgramData%` | Incomplete installs only | Launches the game |
| EA app | Windows uninstall entries + `installerdata.xml` | No | Launches via the EA app (best effort) |
| Ubisoft Connect | Ubisoft registry keys | No | Launches the game |
| Battle.net | Windows uninstall entries | No | Opens Battle.net |
| Wargaming Game Center | Windows uninstall entries | No | Opens Game Center |

Launchers other than Steam don't expose per-game update status. While an update window runs, the launcher panel shows each launcher's live activity instead (for example *DOWNLOADING 12.4 MB/S*, *QUIET*, *DONE*).

**Missing a launcher?** Open a [launcher request](../../issues/new?template=launcher_request.yml), or add it yourself: each launcher is one self-contained block, described in [CONTRIBUTING.md](CONTRIBUTING.md#adding-a-launcher).

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in; PowerShell 7 is not required)

## Install

1. Download `PATCHD-<version>.zip` from the [latest release](../../releases/latest).
2. *(Recommended)* Check the download against `SHA256SUMS.txt` from the same release:
   ```powershell
   Get-FileHash .\PATCHD-<version>.zip -Algorithm SHA256
   ```
3. Extract the zip and double-click **`Install.cmd`**. Approve the administrator prompt.
4. Open **PATCHD** from the Start menu.

The installer:

- copies PATCHD to `C:\Program Files\PATCHD`, a folder only administrators can change
- adds a Start menu shortcut with the PATCHD icon, and a desktop shortcut if you want one
- registers PATCHD in **Settings → Apps** so it uninstalls like any other app
- points an existing nightly task at the new install, if you already had one

**Updating:** download the new release and run `Install.cmd` again. Your settings are kept.

<details>
<summary>Installer options</summary>

Run from PowerShell in the extracted folder:

| Command | Effect |
|---|---|
| `.\Install.cmd -DesktopShortcut` | Install and add a desktop shortcut without asking |
| `.\Install.cmd -NoDesktopShortcut` | Install without a desktop shortcut, without asking |
| `.\Install.cmd -Quiet` | No questions, no "press Enter" at the end |
| `.\Install.cmd -Uninstall` | Remove PATCHD |
| `.\Install.cmd -Uninstall -RemoveUserData` | Remove PATCHD and your settings, log and Steam backups |

</details>

<details>
<summary>Checking detection without opening the window</summary>

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "C:\Program Files\PATCHD\PATCHD.ps1" -ListOnly
```

Prints the games and launchers found, including which picture each game uses.

</details>

## Using it

### Keeping games updated automatically

1. **Turn on automatic updates inside each launcher** — PATCHD starts launchers; the launchers do the patching.
   - **EA app:** Settings → Download → automatic game updates
   - **Ubisoft Connect:** Settings → Downloads → automatic game updates
   - **Battle.net:** Settings → Downloads → Patch & Update → always keep games up to date
   - **Wargaming Game Center:** Settings → automatic game updates
   - **Epic Games:** Settings → automatic updates, then tick each game
   - **Steam:** check Settings → Downloads has no time restriction that blocks your nightly slot
2. **Steam:** press **SET ALL TO IMMEDIATELY** in the *Steam auto-update* panel, and tick **Re-apply nightly**. Steam is closed briefly while this is applied and reopened afterwards.
3. **Test** with **RUN UPDATE WINDOW** and watch the log.
4. **Schedule** it: enter a time and press **ARM**.

### Launcher limits

Some launchers only update games you've played recently, however they're started. Check these settings once so the update window can do its job.

| Launcher | Limit | What to do |
|---|---|---|
| Steam | Postpones updates for games you rarely play | PATCHD fixes this: **SET ALL TO IMMEDIATELY** |
| Battle.net | By default, only recently played games update (including pre-release content) | Battle.net → Settings → Downloads → Automatic updates → **Game specific settings**, then set each game to **Latest & Future Updates** |
| Ubisoft Connect | Only recently played games update, and there is no setting to change it | Open Ubisoft Connect occasionally to update the others |

### Update window settings

| Setting | Default | Meaning |
|---|---|---|
| Warm-up | 5 min | Time for launchers to sign in and check for updates before monitoring starts |
| Done when quiet for | 5 min | A launcher counts as finished once its activity stays low this long |
| Give up after | 120 min | Hard stop. Raise this for very large patches on slower connections |
| Close launchers afterwards | Off | Closes only launchers that PATCHD itself opened |

### Things that still need you

- A launcher waiting on a click (new terms, a login prompt, a confirmation).
- Being signed out of Windows: the task runs in your session, so after a restart it waits until you sign in. Asleep or locked is fine.
- The nightly task wakes the PC by default. Turn this off in Task Scheduler (task *PATCHD nightly updates* → Conditions → "Wake the computer to run this task") if you don't want it.

## Files and data

| Location | Contents |
|---|---|
| `C:\Program Files\PATCHD\` | `PATCHD.ps1`, `PATCHD.ico`, `Install-PATCHD.ps1` (also the uninstaller) |
| Start menu (and optionally desktop) | *PATCHD* shortcut |
| Settings → Apps | *PATCHD* entry, for uninstalling |
| `%LOCALAPPDATA%\PATCHD\settings.json` | Your settings |
| `%LOCALAPPDATA%\PATCHD\update.log` | Update run log (rotates at 1 MB) |
| `%LOCALAPPDATA%\PATCHD\steam-backup\` | Original Steam manifests from before each auto-update change |
| Task Scheduler | *PATCHD nightly updates* (only if you press ARM) |

Nothing leaves your PC. PATCHD makes no network requests of its own.

### Undoing the Steam change

Press **REVERT ALL TO STEAM DECIDES**, or close Steam and copy files back from `%LOCALAPPDATA%\PATCHD\steam-backup\<date-time>\` into the matching `steamapps` folder.

## Uninstall

**Settings → Apps → PATCHD → Uninstall.** This removes the program, shortcuts, nightly task and Apps entry. Your settings, log and Steam backups in `%LOCALAPPDATA%\PATCHD` are kept; delete that folder too if you want them gone.

Steam games keep the automatic-update setting PATCHD gave them. To put them back first, press **REVERT ALL TO STEAM DECIDES** before uninstalling.

## Troubleshooting

| Problem | Fix |
|---|---|
| *"…is not digitally signed. You cannot run this script"* | The installer unblocks installed files, so this usually means PATCHD was copied in manually. Run `Unblock-File "C:\Program Files\PATCHD\*"` from an administrator PowerShell. If it persists, `Get-ExecutionPolicy -List` shows whether Group Policy enforces `AllSigned`; sign the script or ask your administrator. |
| Nothing happens when the shortcut is clicked | Run the `-ListOnly` command above in a PowerShell window to see any error. |
| A launcher shows **BLOCKED: SIGNATURE CHECK FAILED** | Its executable's signature didn't match the expected publisher. Please open an issue with the output of `Get-AuthenticodeSignature "<path to launcher exe>" \| Format-List Status, SignerCertificate`. |
| A game is missing | Run with `-ListOnly` and open an issue with the launcher name and where the game is installed. Please remove anything personal from paths first. |
| Blank cover art or icon | Check the **LOG** panel for a "Couldn't load…" line. |

## Contributing

Bug reports, launcher requests and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md) for the security model, what PATCHD reads and writes, and how to report a vulnerability.

## Disclaimer

PATCHD is an independent project. It is not affiliated with, endorsed by or sponsored by Valve, Epic Games, Electronic Arts, Ubisoft, Blizzard Entertainment or Wargaming. All product names and trademarks belong to their respective owners and are used only to identify the launchers PATCHD works with.

PATCHD edits Steam's per-game update setting only when you ask it to, keeps backups, and never touches accounts, game files or launcher binaries. Launchers can change how they store data at any time, which may break detection or that setting. Use at your own risk; see the licence.

The interface uses fonts that ship with Windows (Bahnschrift, Cascadia Mono or Consolas, Segoe Fluent Icons or Segoe MDL2 Assets), referenced by name; no fonts are included. The only image in this repository is `PATCHD.ico`, an original icon made for this project and covered by the same licence. Cover art and icons shown in the app are read from files already on your PC.

## Building a release

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\build\New-Release.ps1
```

This creates `dist\PATCHD-<version>.zip` and `dist\SHA256SUMS.txt`. Attach both to the GitHub release and paste the hashes into the release notes. The version comes from `$script:Version` in `PATCHD.ps1`.

## Credits

Created by iksta. Built with the help of Claude (Anthropic).

## Licence

[MIT](LICENSE)
