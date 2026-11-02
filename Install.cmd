@echo off
rem PATCHD installer. Double-click to install or update PATCHD.
rem "-ExecutionPolicy Bypass" applies only to this one installer run, so it works on a freshly downloaded copy.
rem The installer unblocks the files it installs, and PATCHD itself always runs under RemoteSigned.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-PATCHD.ps1" %*
