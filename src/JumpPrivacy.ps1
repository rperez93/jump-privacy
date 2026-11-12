# JumpPrivacy.ps1 - black out every physical screen while a Jump Desktop session keeps streaming.
#
#   jump-privacy on | off | toggle | status
#   jump-privacy auto on|off     raise the curtain on Jump connect, drop it on disconnect
#   jump-privacy restore [0-100] put the brightness back by hand: the pending snapshot, else the last desk values,
#                                or the laptop panel to the given percentage
#
# Internal actions: `serve` (the curtain process itself), `event` (run by the JumpPrivacyWatch task on every
# Application-log entry from provider "Jump Desktop Connect", and at logon) and `compile` (run by Install.ps1).
#
# The curtain (Curtain.cs) is an exclude-from-capture black overlay on every physical monitor, so the room sees
# black and the Jump stream sees the desktop. With config.dim (off by default), hardware brightness also drops while it
# is up (DDC/CI on the externals, WMI on the laptop panel). The desk values are written to state.json BEFORE anything
# is dimmed; every exit path restores them, and a snapshot left behind by a crash or reboot is restored by the next
# `event` run (the task also fires at logon) or `off`. Entries that fail to restore are kept for the next attempt.
param([Parameter(Position = 0)][string]$Action = 'status', [Parameter(Position = 1)][string]$Value)
$ErrorActionPreference = 'Stop'
$self = $MyInvocation.MyCommand.Path
$dir = Split-Path -Parent $self
$cfgFile = Join-Path $dir 'config.json'
$stateFile = Join-Path $dir 'state.json'
$logFile = Join-Path $dir 'privacy.log'
$taskName = 'JumpPrivacyWatch'
$mutexName = 'Local\JumpPrivacyCurtain'
$stopName = 'Local\JumpPrivacyStop'

function Log($m) { Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $PID, $m) }
if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 256KB) { Remove-Item $logFile }

function Read-Json($f) { if (Test-Path $f) { try { return Get-Content $f -Raw | ConvertFrom-Json } catch {} }; $null }
# Defaults first, config.json on top: a file missing a key still works, and the key is written back on the next save.
$cfg = [pscustomobject]@{ auto = $false; dim = $false; panelBrightness = 0; externalBrightness = 0; hotkey = 'Ctrl+Alt+Shift+P'; lockOnDisconnect = $true }
$fileCfg = Read-Json $cfgFile
if ($fileCfg) { foreach ($p in $fileCfg.PSObject.Properties) { $cfg | Add-Member -Force $p.Name $p.Value } }
function Save-Config { $cfg | ConvertTo-Json | Set-Content $cfgFile -Encoding UTF8 }
function Get-State { $s = Read-Json $stateFile; if ($s) { $s } else { [pscustomobject]@{} } }
function Save-State($s) { $s | ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8 }
function Set-StateField($name, $v) { $s = Get-State; if ($null -eq $v) { $s.PSObject.Properties.Remove($name) } else { $s | Add-Member -Force $name $v }; Save-State $s }

# Compile Curtain.cs once per content hash (Install.ps1 does it ahead of time); later runs load the cached assembly.
function Import-Curtain {
  if ('JumpPrivacy.Host' -as [type]) { return }
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $src = Join-Path $dir 'Curtain.cs'
  $dll = Join-Path $dir ('Curtain.{0}.dll' -f (Get-FileHash $src -Algorithm SHA256).Hash.Substring(0, 12))
  if (-not (Test-Path $dll)) {
    Get-ChildItem $dir -Filter 'Curtain.*.dll' | Remove-Item -Force -ErrorAction SilentlyContinue
    Add-Type -Path $src -ReferencedAssemblies System.Windows.Forms, System.Drawing -OutputAssembly $dll -OutputType Library
  }
  Add-Type -Path $dll
}

function Test-Running {
  $m = $null
  if ([Threading.Mutex]::TryOpenExisting($mutexName, [ref]$m)) { $m.Dispose(); return $true }
  $false
}

# --- Jump sessions, from the Application log --------------------------------------------------------------------
# Open = authenticated and not yet closed, counting only events since the Jump service last started (a service crash
# never logs "Connection closed", and a restart ends every session anyway). Falls back to boot time.
function Get-JumpEvents {
  $since = $null
  try {
    $svc = Get-CimInstance Win32_Service -Filter "Name='JumpConnect'"
    if ($svc.ProcessId) { $since = (Get-CimInstance Win32_Process -Filter "ProcessId=$($svc.ProcessId)").CreationDate }
  } catch {}
  if (-not $since) { $since = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
  Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Jump Desktop Connect'; StartTime = $since } -ErrorAction SilentlyContinue
}
function Get-OpenSessions { Resolve-Sessions (Get-JumpEvents) }
# Events (anything with TimeCreated, RecordId, Message or Properties) -> connection IDs authenticated and not yet closed.
function Resolve-Sessions($events) {
  $open = [ordered]@{}
  foreach ($e in ($events | Sort-Object TimeCreated, RecordId)) {
    # Message is rendered through Jump's message file, which lives in a versioned install folder: events written by
    # anything else (or before an upgrade removed that folder) render empty. The insertion string holds the same text.
    $text = $e.Message
    if (-not $text -and $e.Properties -and $e.Properties.Count) { $text = [string]$e.Properties[0].Value }
    if ($text -match '^(Authentication Succeeded|Connection closed): ConnectionID:([^,\s]+)') {
      if ($Matches[1] -eq 'Authentication Succeeded') { $open[$Matches[2]] = $e.TimeCreated } else { $open.Remove($Matches[2]) }
    }
  }
  @($open.Keys)
}
# Same replay -> the time of the last "Connection closed" at or after $after that left no session open, else $null.
# The lock decision uses this rather than the open count at the moment of checking: after an iPad disconnect the
# display stack can stall every process for ~30 s, and a reconnect inside that stall used to hide the gap (2026-11-12).
function Find-Gap($events, [datetime]$after) {
  $open = [ordered]@{}; $gap = $null
  foreach ($e in ($events | Sort-Object TimeCreated, RecordId)) {
    $text = $e.Message
    if (-not $text -and $e.Properties -and $e.Properties.Count) { $text = [string]$e.Properties[0].Value }
    if ($text -match '^(Authentication Succeeded|Connection closed): ConnectionID:([^,\s]+)') {
      if ($Matches[1] -eq 'Authentication Succeeded') { $open[$Matches[2]] = $e.TimeCreated }
      elseif ($open.Contains($Matches[2])) { $open.Remove($Matches[2]); if (-not $open.Count -and $e.TimeCreated -ge $after) { $gap = $e.TimeCreated } }
    }
  }
  $gap
}

# --- hardware brightness ---------------------------------------------------------------------------------------
function Get-PanelBrightness { $b = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue | Select-Object -First 1; if ($b) { [int]$b.CurrentBrightness } }
function Set-PanelBrightness([int]$v) {
  $m = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $m) { return $false }
  try { Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]1; Brightness = [byte]$v } | Out-Null; $true } catch { $false }
}
function Format-Ext($o) { ($o.PSObject.Properties | ForEach-Object { '{0}={1}' -f ($_.Name -replace '^\\\\\.\\', ''), $_.Value }) -join ',' }
function Invoke-Dim {
  if (-not $cfg.dim) { return }
  $st = Get-State
  if (-not $st.restore) {                                   # keep an older unrestored snapshot: it holds the real desk values
    $ext = @{}; foreach ($kv in ([JumpPrivacy.Ddc]::Get(0x10)).GetEnumerator()) { $ext[$kv.Key] = $kv.Value }
    Set-StateField restore ([pscustomobject]@{ panel = (Get-PanelBrightness); external = [pscustomobject]$ext })
    Set-StateField desk (Get-State).restore                 # survives the restore, for a manual `restore` later
    $st = Get-State
  }
  $done = @()
  foreach ($p in $st.restore.external.PSObject.Properties) { if ([JumpPrivacy.Ddc]::Set($p.Name, 0x10, [uint32]$cfg.externalBrightness)) { $done += ($p.Name -replace '^\\\\\.\\', '') } }
  $pan = if ($null -ne $st.restore.panel) { Set-PanelBrightness $cfg.panelBrightness } else { 'n/a' }
  Log ('dimmed: panel {0}->{1} (ok={2}); external {3} -> {4} (ok: {5})' -f $st.restore.panel, $cfg.panelBrightness, $pan, (Format-Ext $st.restore.external), $cfg.externalBrightness, ($done -join ','))
}
function Invoke-Restore {
  $st = Get-State
  if (-not $st.restore) { return }
  Import-Curtain
  $r = $st.restore; $failed = @()
  foreach ($p in @($r.external.PSObject.Properties)) {
    if ([JumpPrivacy.Ddc]::Set($p.Name, 0x10, [uint32]$p.Value)) { $r.external.PSObject.Properties.Remove($p.Name) } else { $failed += $p.Name }
  }
  if ($null -ne $r.panel) { if (Set-PanelBrightness ([int]$r.panel)) { $r.panel = $null } else { $failed += 'panel' } }
  if ($failed.Count -eq 0) { Set-StateField restore $null; Log 'restored brightness' }
  else { Set-StateField restore $r; Log ('restore incomplete, kept for retry: {0}' -f ($failed -join ',')) }
}

# Manual recovery for a restore that reported success but left a screen dark. Sets, waits, reads back.
function Invoke-ManualRestore([string]$v) {
  if (Test-Running) { return 'Curtain is up; drop it with: jump-privacy off' }
  foreach ($k in 'pid', 'since', 'why', 'hotkeyOk') { Set-StateField $k $null }   # left behind by a killed curtain
  Import-Curtain
  $st = Get-State
  if ($v) {
    if ($v -notmatch '^\d+$' -or [int]$v -gt 100) { return 'Usage: jump-privacy restore [0-100]' }
    $src = 'requested'; $t = [pscustomobject]@{ panel = [int]$v; external = [pscustomobject]@{} }
  } elseif ($st.restore) { $src = 'pending snapshot'; $t = $st.restore }
  elseif ($st.desk) { $src = 'last desk values'; $t = $st.desk }
  else { return ('No snapshot recorded yet; panel reads {0}. Give a value: jump-privacy restore 70' -f (Get-PanelBrightness)) }
  $out = @()
  if ($null -ne $t.panel) {
    $ok = Set-PanelBrightness ([int]$t.panel); Start-Sleep -Milliseconds 400
    $now = Get-PanelBrightness
    if (-not $ok -or $now -ne [int]$t.panel) { [void](Set-PanelBrightness ([int]$t.panel)); Start-Sleep -Milliseconds 400; $now = Get-PanelBrightness }
    $out += 'panel {0} -> reads {1}' -f $t.panel, $now
  }
  foreach ($p in @($t.external.PSObject.Properties)) {
    $out += '{0} {1} ({2})' -f ($p.Name -replace '^\\\\\.\\', ''), $p.Value, $(if ([JumpPrivacy.Ddc]::Set($p.Name, 0x10, [uint32]$p.Value)) { 'ok' } else { 'FAILED' })
  }
  if ($st.restore -and -not $v) { Set-StateField restore $null }
  Log ('manual restore ({0}): {1}' -f $src, ($out -join '; '))
  "Restored from $src`: " + ($out -join '; ')
}

# --- the curtain process ---------------------------------------------------------------------------------------
function Convert-Hotkey([string]$s) {
  if (-not $s) { return @(0, 0) }
  $mod = 0; $vk = 0
  foreach ($p in $s -split '\+') {
    switch ($p.Trim().ToLower()) { 'alt' { $mod += 1 } { $_ -in 'ctrl', 'control' } { $mod += 2 } 'shift' { $mod += 4 } 'win' { $mod += 8 }
      default { $vk = [int][Enum]::Parse([Windows.Forms.Keys], $p.Trim(), $true) } }
  }
  @($mod, $vk)
}
function Start-Serve([string]$why) {
  $created = $false
  $mutex = New-Object Threading.Mutex($true, $mutexName, [ref]$created)
  if (-not $created) { Log "serve ($why): already running"; $mutex.Dispose(); return }
  # Stop event and pid first, so an `off` arriving while this process is still starting can reach it.
  $stop = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $stopName)
  Set-StateField pid $PID; Set-StateField since (Get-Date).ToString('s'); Set-StateField why $why
  $script:why = $why; $script:upAt = Get-Date; $script:gapClose = $false
  try {
    Import-Curtain
    if ($why -eq 'auto' -and (Get-OpenSessions).Count -eq 0) { Log 'serve (auto): session already over, not raising'; return }
    [void][JumpPrivacy.Native]::SetProcessDpiAwarenessContext([JumpPrivacy.Native]::PER_MONITOR_AWARE_V2)
    $hk = Convert-Hotkey $cfg.hotkey
    $hostForm = New-Object JumpPrivacy.Host($stop, [uint32]$hk[0], [uint32]$hk[1])
    $hostForm.Log = [Action[string]] { param($m) Log $m }
    $hostForm.Ready = [Action[bool]] { param($ok)
      Set-StateField hotkeyOk $ok
      if (-not $ok) { Log "WARNING: hotkey $($cfg.hotkey) could not be registered (taken by another app?)" }
      try { Invoke-Dim } catch { Log "dim failed: $_" } }       # panes are up before the brightness drops
    # down when no session is open now, or when every session closed at some point since the curtain went up
    if ($why -eq 'auto') { $hostForm.KeepUp = [Func[bool]] { $ev = Get-JumpEvents; (Resolve-Sessions $ev).Count -gt 0 -and -not (Find-Gap $ev $script:upAt) } }
    $hostForm.BeforeClose = [Action[string]] { param($reason)
      # Lock while the panes still cover the screens, so the room goes from black to the lock screen.
      if ($script:why -ne 'auto' -or $reason -eq 'hotkey') { return }
      $ev = Get-JumpEvents; $gap = Find-Gap $ev $script:upAt; $n = (Resolve-Sessions $ev).Count
      $script:gapClose = [bool]$gap -and $n -gt 0                # a new session is already open: raise again after
      if ($cfg.lockOnDisconnect -and ($gap -or $n -eq 0)) {
        [void][JumpPrivacy.Native]::LockWorkStation()
        Log ('locked workstation' + $(if ($gap) { ' (every session closed at {0:HH:mm:ss}{1})' -f $gap, $(if ($n) { ", $n open again since" } else { '' }) } else { '' }))
        Start-Sleep -Milliseconds 1500 } }
    Log "curtain up ($why)"
    [Windows.Forms.Application]::Run($hostForm)
    Log ("curtain down ({0})" -f $hostForm.Reason)
  } catch { Log "serve error: $_" }
  finally {
    try { Invoke-Restore } catch { Log "restore failed: $_" }
    foreach ($k in 'pid', 'since', 'why', 'hotkeyOk') { Set-StateField $k $null }
    $stop.Dispose(); $mutex.ReleaseMutex(); $mutex.Dispose()
  }
  if ($script:gapClose -and $cfg.auto) {                    # the reconnect's own event run found this curtain still up
    Log 'new session already open -> curtain raised again'
    Start-Process -FilePath "$env:SystemRoot\System32\conhost.exe" -ArgumentList "--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$self`" serve auto" -WindowStyle Hidden
  }
}

function Invoke-On([string]$why) {
  if (Test-Running) { 'Curtain already up.'; return }
  $a = "--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$self`" serve $why"
  Start-Process -FilePath "$env:SystemRoot\System32\conhost.exe" -ArgumentList $a -WindowStyle Hidden
  for ($i = 0; $i -lt 60 -and -not (Test-Running); $i++) { Start-Sleep -Milliseconds 250 }
  if (-not (Test-Running)) { return 'Curtain failed to start; see privacy.log.' }
  for ($i = 0; $i -lt 40 -and $null -eq (Get-State).hotkeyOk; $i++) { Start-Sleep -Milliseconds 250 }
  $ok = (Get-State).hotkeyOk
  'Curtain up. Release: jump-privacy off' + $(if ($ok) { ", or $($cfg.hotkey)." } else { ". WARNING: hotkey $($cfg.hotkey) is NOT registered." })
}
function Invoke-Off([string]$why) {
  if (Test-Running) {
    $e = $null
    if ([Threading.EventWaitHandle]::TryOpenExisting($stopName, [ref]$e)) { [void]$e.Set() }
    for ($i = 0; $i -lt 40 -and (Test-Running); $i++) { Start-Sleep -Milliseconds 250 }
    if ($e) { $e.Dispose() }
    if (Test-Running) {                                     # wedged: kill it, then restore here
      $p = (Get-State).pid; if ($p) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue; Log "killed wedged curtain $p ($why)" }
      Start-Sleep -Milliseconds 500
      foreach ($k in 'pid', 'since', 'why', 'hotkeyOk') { Set-StateField $k $null }
    }
  }
  Invoke-Restore                                            # no-op unless a snapshot is still pending (crash path)
  'Curtain down.'
}

# --- listener: decide from the Jump event log, so every run is idempotent ------------------------------------------
function Invoke-Event {
  $running = Test-Running
  if (-not $running -and (Get-State).restore) { Log 'event: pending brightness snapshot without a curtain -> restore'; Invoke-Restore }
  if (-not $cfg.auto) { return }
  $ev = Get-JumpEvents; $open = Resolve-Sessions $ev; $st = Get-State
  if ($running -and $st.why -eq 'auto' -and $st.since) {    # a disconnect this run was too late to see as "no sessions"
    $gap = Find-Gap $ev ([datetime]$st.since)
    if ($gap) { Log ('event: every session closed at {0:HH:mm:ss} -> off' -f $gap); [void](Invoke-Off 'auto'); $running = Test-Running }
  }
  if ($open.Count -gt 0) {
    if (-not $running) { Log ('event: open sessions {0} -> on' -f ($open -join ',')); Start-Serve 'auto' }
  } elseif ($running -and (Get-State).why -eq 'auto') {
    Log 'event: no open sessions -> off'; [void](Invoke-Off 'auto')
  }
}

switch ($Action.ToLower()) {
  'on'      { Invoke-On 'manual' }
  'off'     { Invoke-Off 'manual' }
  'toggle'  { if (Test-Running) { Invoke-Off 'manual' } else { Invoke-On 'manual' } }
  'serve'   { Start-Serve $(if ($Value) { $Value } else { 'manual' }) }
  'event'   { Invoke-Event }
  'restore' { Invoke-ManualRestore $Value }
  'selftest' {                                              # session logic against synthetic event sequences
    $t = Get-Date; $n = 0
    function E($sec, $msg) { $script:n++; [pscustomobject]@{ TimeCreated = $t.AddSeconds($sec); RecordId = $script:n; Message = $msg } }
    $a = 'Authentication Succeeded: ConnectionID:{0}, Type:Local'; $c = 'Connection closed: ConnectionID:{0}, PeerID:X'
    $cases = [ordered]@{
      'auth only'                 = @((E 0 ($a -f 'A')));                                        # -> A
      'auth then close in 1 s'    = @((E 0 ($a -f 'A')), (E 1 ($c -f 'A')));                     # -> none
      'overlapping sessions'      = @((E 0 ($a -f 'A')), (E 5 ($a -f 'B')), (E 9 ($c -f 'A')));  # -> B
      'close without auth'        = @((E 0 'Incomming Connection Request: ConnectionID:Z'), (E 1 ($c -f 'Z')));   # -> none
      'same timestamp, log order' = @((E 0 ($a -f 'A')), (E 0 ($c -f 'A')));                     # -> none
    }
    foreach ($k in $cases.Keys) { '{0,-26} -> [{1}]' -f $k, ((Resolve-Sessions $cases[$k]) -join ',') }
    $gaps = [ordered]@{                                     # Find-Gap with the curtain up at +2 s
      'close, reconnect (race)'   = @((E 0 ($a -f 'A')), (E 10 ($c -f 'A')), (E 40 ($a -f 'B')));   # -> +10
      'overlap, never empty'      = @((E 0 ($a -f 'A')), (E 5 ($a -f 'B')), (E 9 ($c -f 'A')));     # -> none
      'empty before curtain up'   = @((E 0 ($a -f 'A')), (E 1 ($c -f 'A')), (E 3 ($a -f 'B')));     # -> none
      'stray close, no auth'      = @((E 0 ($a -f 'A')), (E 9 ($c -f 'Z')));                         # -> none
    }
    foreach ($k in $gaps.Keys) { $g = Find-Gap $gaps[$k] $t.AddSeconds(2); 'gap: {0,-24} -> {1}' -f $k, $(if ($g) { '+' + [int]($g - $t).TotalSeconds + ' s' } else { 'none' }) }
  }
  'compile' { Import-Curtain; 'compiled: ' + (Get-ChildItem $dir -Filter 'Curtain.*.dll').Name }
  'auto'    {
    if ($Value -notin 'on', 'off') { "auto is $(if ($cfg.auto) { 'on' } else { 'off' }). Usage: jump-privacy auto on|off"; break }
    $cfg.auto = ($Value -eq 'on'); Save-Config              # the task stays enabled either way: it also restores brightness at logon
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Log "auto $Value"
    if (-not $cfg.auto -and (Test-Running) -and (Get-State).why -eq 'auto') { [void](Invoke-Off 'auto-disabled'); 'Dropped the auto-raised curtain.' }
    "auto $Value" + $(if (-not $t) { " (task $taskName not installed - run Install.ps1)" } else { " (task $((Get-ScheduledTask -TaskName $taskName).State))" })
  }
  'status'  {
    $st = Get-State; $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    'curtain : ' + $(if (Test-Running) { "UP since $($st.since) ($($st.why), pid $($st.pid)); hotkey registered: $($st.hotkeyOk)" } else { 'down' })
    'auto    : ' + $(if ($cfg.auto) { 'on' } else { 'off' }) + ' (task ' + $(if ($t) { "$($t.State), instances $($t.Settings.MultipleInstances), limit $($t.Settings.ExecutionTimeLimit)" } else { 'not installed' }) + ')'
    'sessions: ' + (@(Get-OpenSessions) -join ', ')
    'dim     : ' + $(if ($cfg.dim) { "on (panel -> $($cfg.panelBrightness), externals -> $($cfg.externalBrightness))" } else { 'off' })
    'hotkey  : ' + $cfg.hotkey + '   lock on disconnect: ' + $cfg.lockOnDisconnect
    if ($st.desk) { 'desk    : panel ' + $st.desk.panel + '; ' + (Format-Ext $st.desk.external) + '   (jump-privacy restore)' }
    if ($st.restore) { 'pending : brightness snapshot not yet restored (panel ' + $st.restore.panel + '; ' + (Format-Ext $st.restore.external) + ')' }
  }
  default { 'Usage: jump-privacy on|off|toggle|status|auto on|off|restore [0-100]' }
}
