# Install.ps1 - installs jump-privacy for the interactive user (no admin needed):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Install.ps1      (or ./install.sh from WSL)
# Copies the engine to %LOCALAPPDATA%\JumpPrivacy (config.json only if absent, so settings survive upgrades),
# precompiles the curtain, puts jump-privacy.cmd in %USERPROFILE%\bin, and registers the JumpPrivacyWatch task.
#
# The task runs `JumpPrivacy.ps1 event` on every Application-log entry from provider "Jump Desktop Connect" and at
# logon. `event` restores any brightness snapshot a crash or reboot left behind, then - only if config.auto is true -
# raises or drops the curtain from the session state in the log. The run that raises the curtain IS the curtain
# process, so the task must have NO time limit (PT0S) and allow PARALLEL instances, or the disconnect run could not
# reach it. Do not copy JumpDpiWatch's PT2M/IgnoreNew here: the curtain would be killed mid-session.
param([string]$Dest = "$env:LOCALAPPDATA\JumpPrivacy", [string]$BinDir = "$env:USERPROFILE\bin")
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path $Dest, $BinDir | Out-Null
if (Test-Path "$Dest\JumpPrivacy.ps1") { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Dest\JumpPrivacy.ps1" off | Out-Null }
foreach ($f in 'JumpPrivacy.ps1', 'Curtain.cs') { Copy-Item (Join-Path $here $f) $Dest -Force }
if (-not (Test-Path (Join-Path $Dest 'config.json'))) { Copy-Item (Join-Path $here 'config.json') $Dest }
Copy-Item (Join-Path $here '..\bin\jump-privacy.cmd') $BinDir -Force
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$Dest\JumpPrivacy.ps1" compile

$query = "<QueryList><Query Id=`"0`" Path=`"Application`"><Select Path=`"Application`">*[System[Provider[@Name='Jump Desktop Connect']]]</Select></Query></QueryList>"
$class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$onJump = New-CimInstance -CimClass $class -ClientOnly -Property @{ Enabled = $true; Subscription = $query }
$onLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
# conhost --headless: no console window. -STA: WinForms.
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument "--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$Dest\JumpPrivacy.ps1`" event"
$settings = New-ScheduledTaskSettingsSet -MultipleInstances Parallel -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'JumpPrivacyWatch' -Trigger $onJump, $onLogon -Action $action -Settings $settings -Principal $principal -Force | Out-Null
$t = Get-ScheduledTask -TaskName 'JumpPrivacyWatch'
"JumpPrivacyWatch registered: $($t.State), instances $($t.Settings.MultipleInstances), limit $($t.Settings.ExecutionTimeLimit)"
"Command: $BinDir\jump-privacy.cmd  (on | off | toggle | status | auto on|off)"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Dest\JumpPrivacy.ps1" status
