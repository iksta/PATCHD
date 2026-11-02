## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## How I tested it

<!-- Windows version, which launchers and games, what you clicked. -->

## Checklist

- [ ] Works in **Windows PowerShell 5.1** (no PowerShell 7-only syntax)
- [ ] No new dependencies, network calls, `Add-Type` or `Invoke-Expression`
- [ ] `.ps1` files are plain ASCII
- [ ] Paths from launcher data go through `Get-SafeDir` / `Get-SafeFile` / `Find-FirstFile`, and IDs are validated
- [ ] New launcher: added with `Register-Launcher`, not **BLOCKED**, tested with `-ListOnly`, launch and the update window
- [ ] `README.md` (and `SECURITY.md` if relevant) updated
- [ ] No personal data (usernames, PC names, personal paths) in code, comments or screenshots
