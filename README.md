# jump-privacy

Black out every physical screen of a Windows host — laptop panel with the lid open included — while a
[Jump Desktop](https://jumpdesktop.com) session keeps streaming the desktop to the remote device.

```
jump-privacy on | off | toggle | status
jump-privacy auto on|off        raise the curtain on Jump connect, drop it on disconnect
```

Works from Win+R / cmd (`%USERPROFILE%\bin\jump-privacy.cmd`) and from WSL (`~/.local/bin/jump-privacy`).
Panic hotkey while the curtain is up: **Ctrl+Alt+Shift+P** (typeable from an iPad keyboard, works at the desk too).

## How it works

- **Curtain.** One black, topmost, click-through window per *physical* monitor, flagged
  `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`. Windows shows it on the panels and omits it from screen capture,
  so the room sees black while Jump streams the desktop underneath. Input passes straight through.
- **Hardware dimming** (`dim`). While the curtain is up, brightness drops to `externalBrightness` on the external
  monitors (DDC/CI VCP 0x10) and `panelBrightness` on the laptop panel (WMI). The desk values are saved to
  `state.json` before anything is dimmed. Every exit restores them, and so does the next `event` or `off` after a
  crash or reboot. A value that fails to restore is kept for the next attempt.
- **Follows mode changes.** Jump switches the display mode after connecting. The curtain re-reads the monitor
  layout every 500 ms and on `WM_DISPLAYCHANGE`, moving panes in place.
- **Virtual monitors are never covered.** Jump's own IddCx display, or any indirect display, gets no pane.
  Only paths on a real connector (HDMI, DisplayPort, eDP, …) count as physical.
- **Listener.** The `JumpPrivacyWatch` scheduled task runs `JumpPrivacy.ps1 event` on every Application-log entry
  from provider "Jump Desktop Connect" and at logon. `event` restores any leftover brightness snapshot. Then, if
  `auto` is true, it raises or drops the curtain from the session state in the log. A session is open if it has an
  `Authentication Succeeded` event with no matching `Connection closed`, counting only events since the Jump
  service last started. An auto-raised curtain also re-checks that state every 5 s, so a session that ends before
  the curtain is up cannot strand it.
- **Lock on disconnect** (`lockOnDisconnect`). When an auto curtain drops because the last session ended, the
  workstation locks while the panes still cover the screens. The room goes from black to the lock screen, never to
  the desktop. Releasing with the hotkey does not lock.

## Install

```
./install.sh                 # from WSL: runs src/Install.ps1, links the WSL shim
# or, on Windows:
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Install.ps1
```

No admin rights are needed. Installs to `%LOCALAPPDATA%\JumpPrivacy`: `config.json` is kept across upgrades,
the log is `privacy.log`, and the curtain is precompiled to `Curtain.<hash>.dll`. The task must stay
**Parallel / no time limit**: the run that raises the curtain *is* the curtain process.

## config.json

| key | default | meaning |
|---|---|---|
| `auto` | `false` | engage on Jump connect / release on disconnect (`jump-privacy auto on\|off`) |
| `dim` | `true` | hardware brightness to the values below while the curtain is up |
| `panelBrightness` | `0` | laptop panel, WMI 0–100 |
| `externalBrightness` | `0` | external monitors, DDC/CI 0–100 |
| `hotkey` | `Ctrl+Alt+Shift+P` | release hotkey (`Ctrl`/`Alt`/`Shift`/`Win` + a `System.Windows.Forms.Keys` name) |
| `lockOnDisconnect` | `true` | lock the workstation when an auto curtain drops at session end |

## Verified on the host (GU604VI, Windows 11 25H2, Jump Connect 10.15.28), 2026-09-24

Mean luma of each monitor, captured during the curtain through **Desktop Duplication** (`ffmpeg ddagrab`) and
**Windows.Graphics.Capture** (`ffmpeg gfxcapture`):

| | DDA (3 monitors) | WGC (3 monitors) |
|---|---|---|
| no curtain | 192.8 / 20.8 / 33.0 | 192.8 / 33.0 / 20.8 |
| curtain up | 192.8 / 20.5 / 32.6 | 192.8 / 32.6 / 20.5 |

The desktop stayed visible to both capture paths. Jump's DLL contains both a Desktop Duplication capturer and a
WGC capturer. Other results:

- **Brightness.** 54 / 53 / 66 went to 0 / 0 / 0 and back to 54 / 53 / 66.
- **Crash restore.** The curtain was killed with `-Force`; the next `event` restored brightness.
- **Mode change.** A monitor switched to 1920x1080 under the curtain; its pane moved within one tick and returned.
- **Auto engage.** Curtain up 4 s after an `Authentication Succeeded` event.
- **Auto release.** Curtain down 5 s after the matching `Connection closed`.
- **Short session.** A session closed 1 s after authenticating never raised the curtain.
- **Focus.** The foreground window was unchanged by `on`.
- **Real log.** The session resolver matches the log: 570 events, 114 sessions, none left open.

**Still to be verified by eye and from the iPad:** all three panels black with no gaps, the iPad image normal
in a live session (including after Jump's mode switch), the hotkey from the iPad keyboard, and the lock at
disconnect.

## Known limits

- **Not power-off.** The externals are backlit at brightness 0, and IPS panels glow. For true power-off, see below.
- **The mouse pointer** (hardware cursor plane) can show above the curtain.
- **Some shell surfaces sit above topmost windows.** The Start menu, Search, Alt+Tab thumbnails, notifications,
  volume flyouts and UIAccess apps draw above any topmost window. If they are opened from the iPad, they appear
  on the physical screens, dimmed.
- **Secure desktop surfaces are not covered.** UAC prompts, Ctrl+Alt+Del and the lock screen are a separate
  desktop. The lock screen shows no content.
- **Local input is not blocked.** Someone at the desk can operate the session blind. Jump's own Privacy Mode
  blocks input, but on this host it paints the screens white at full brightness and can leave the laptop panel
  uncovered, which is why this tool exists. Turn Jump's Privacy Mode **off** so the two do not stack.
- **Brightness can be re-applied mid-session.** An AC/battery switch or an Armoury Crate profile change may
  restore brightness. The black curtain still covers the screens.

## True power-off: Jump 10 "Single Virtual Display" (no code, verify once)

Jump Desktop 10 (GA 2026-09-23) lets the iPad client stream a virtual display that is "used in place of the
monitors plugged into the host". To select it, go to toolbar → Settings → **Display** → Presets →
**Single Virtual Display**, or answer the first-connect prompt. If Jump detaches the physical paths, which is
undocumented, all three panels lose signal. The virtual display also matches the iPad's native resolution.
jump-privacy then covers nothing, because it never puts a pane on a virtual monitor.

Before trying it, learn the blind recovery in case the desk is left without a picture:

1. **Win+P**, then **↑** to the first entry ("PC screen only"), then **Enter**.
2. If that does not work, **Win+Ctrl+Shift+B** (graphics driver reset).
3. If that does not work either, reconnect from the iPad and switch back to Host Displays.

## License

MIT-style licence with a **commercial use restriction** — see [LICENSE](LICENSE). Free for personal,
educational and non-profit use. Any commercial use (selling it, shipping it in a paid product or service, or using
it inside a for-profit organisation) needs written permission first: open an issue here or contact
[@rperez93](https://github.com/rperez93). This is a source-available licence, not an OSI-approved open-source one.
