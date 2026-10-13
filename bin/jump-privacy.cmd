@echo off
rem jump-privacy - black out the physical screens while Jump streams. on | off | toggle | status | auto on|off | restore [0-100]
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\JumpPrivacy\JumpPrivacy.ps1" %*
