// Curtain.cs - the privacy curtain engine for JumpPrivacy.ps1 (compiled once by `JumpPrivacy.ps1 compile`).
//
// One black, borderless, topmost, click-through window per PHYSICAL monitor, flagged with
// SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE): Windows shows it on the panel and omits it from screen
// capture, so a Jump session keeps streaming the desktop underneath while the room sees black. Input passes
// through (WS_EX_TRANSPARENT), so the remote pointer and clicks reach the windows below.
//
// Virtual monitors (Jump's own IddCx display, or any indirect display) never get a pane: a pane drawn into a
// virtual display would be what the remote end sees. A monitor counts as physical only if its active path uses
// a real connector (HDMI, DisplayPort, eDP, DVI, ...) and its name does not identify a virtual display.
//
// Jump changes the display mode after connecting, so monitor rectangles move mid-session. The layout is
// re-checked every 500 ms and on WM_DISPLAYCHANGE; existing panes are moved in place (no flash), and TOPMOST is
// re-asserted each tick. Ends when the named event Local\JumpPrivacyStop is set, the panic hotkey is pressed, or
// the KeepUp callback (the auto mode's own session check) returns false.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace JumpPrivacy {
  public class Pane : Form {
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr h, uint a);
    [DllImport("user32.dll")] static extern bool GetWindowDisplayAffinity(IntPtr h, out uint a);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    public uint Affinity { get; private set; }
    public Pane(Rectangle b) {
      FormBorderStyle = FormBorderStyle.None; BackColor = Color.Black; ShowInTaskbar = false;
      StartPosition = FormStartPosition.Manual; Bounds = b; TopMost = true;
    }
    protected override CreateParams CreateParams { get {
      var cp = base.CreateParams;
      cp.ExStyle |= 0x80 | 0x20 | 0x80000 | 0x08000000 | 0x8;   // TOOLWINDOW | TRANSPARENT | LAYERED | NOACTIVATE | TOPMOST
      return cp; } }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void OnHandleCreated(EventArgs e) {
      base.OnHandleCreated(e);
      SetLayeredWindowAttributes(Handle, 0, 255, 2);             // LWA_ALPHA, fully opaque
      SetWindowDisplayAffinity(Handle, WDA_EXCLUDEFROMCAPTURE);
      uint a; GetWindowDisplayAffinity(Handle, out a); Affinity = a;
    }
  }

  public class Host : Form {                                     // invisible owner: hotkey, display changes, ticking
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    const uint NOSIZE = 0x1, NOMOVE = 0x2, NOACTIVATE = 0x10;
    readonly Dictionary<string, Pane> panes = new Dictionary<string, Pane>();
    readonly System.Windows.Forms.Timer tick = new System.Windows.Forms.Timer();
    readonly EventWaitHandle stop;
    readonly uint hkMod, hkVk;
    string layout = "";
    int ticks;
    public bool HotkeyOk; public string Reason = "stop";
    public Action<string> Log = s => { };
    public Action<bool> Ready = ok => { };
    public Action<string> BeforeClose = reason => { };               // runs while the panes are still up (e.g. lock first)
    public Func<bool> KeepUp;                                    // optional; polled every KeepUpEvery ticks
    public int KeepUpEvery = 10;

    public Host(EventWaitHandle stopEvent, uint mod, uint vk) {
      stop = stopEvent; hkMod = mod; hkVk = vk;
      ShowInTaskbar = false; FormBorderStyle = FormBorderStyle.None; Opacity = 0; Size = new Size(1, 1);
      StartPosition = FormStartPosition.Manual; Location = new Point(-32000, -32000);
      tick.Interval = 500; tick.Tick += (s, e) => Tick();
    }
    protected override CreateParams CreateParams { get { var cp = base.CreateParams; cp.ExStyle |= 0x80 | 0x08000000; return cp; } }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void OnLoad(EventArgs e) {
      base.OnLoad(e);
      if (stop.WaitOne(0)) { Reason = "stop"; BeginInvoke((Action)Close); return; }   // an `off` that beat us here
      if (hkVk != 0) HotkeyOk = RegisterHotKey(Handle, 1, hkMod | 0x4000, hkVk);   // MOD_NOREPEAT
      Relayout(); tick.Start(); Ready(HotkeyOk);
    }
    void Relayout() {
      var want = Displays.Physical();
      foreach (var gone in panes.Keys.Where(k => !want.ContainsKey(k)).ToList()) { panes[gone].Close(); panes.Remove(gone); }
      foreach (var kv in want) {
        Pane p;
        if (panes.TryGetValue(kv.Key, out p)) {
          if (p.Bounds != kv.Value) SetWindowPos(p.Handle, HWND_TOPMOST, kv.Value.X, kv.Value.Y, kv.Value.Width, kv.Value.Height, NOACTIVATE);
        } else { p = new Pane(kv.Value); p.Show(); panes[kv.Key] = p; }
      }
      layout = Displays.Signature(want);
      Log("cover " + (layout.Length > 0 ? layout : "(no physical monitor active)") + " affinity=" +
          string.Join(",", panes.Values.Select(p => "0x" + p.Affinity.ToString("X"))));
    }
    void Tick() {
      if (stop.WaitOne(0)) { Reason = "stop"; Close(); return; }
      if (KeepUp != null && ++ticks % KeepUpEvery == 0) {
        bool keep = true;
        try { keep = KeepUp(); } catch (Exception ex) { Log("keep-up check failed: " + ex.Message); }
        if (!keep) { Reason = "session-ended"; Close(); return; }
      }
      if (Displays.Signature(Displays.Physical()) != layout) { Relayout(); return; }
      foreach (var p in panes.Values) SetWindowPos(p.Handle, HWND_TOPMOST, 0, 0, 0, 0, NOMOVE | NOSIZE | NOACTIVATE);
    }
    protected override void WndProc(ref Message m) {
      if (m.Msg == 0x0312 && m.WParam.ToInt32() == 1) { Reason = "hotkey"; Close(); return; }   // WM_HOTKEY
      if (m.Msg == 0x007E) BeginInvoke((Action)(() => { if (!IsDisposed && Displays.Signature(Displays.Physical()) != layout) Relayout(); }));   // WM_DISPLAYCHANGE
      base.WndProc(ref m);
    }
    protected override void OnFormClosed(FormClosedEventArgs e) {
      tick.Stop(); UnregisterHotKey(Handle, 1);
      try { BeforeClose(Reason); } catch (Exception ex) { Log("closing hook failed: " + ex.Message); }
      foreach (var p in panes.Values) p.Close();
      panes.Clear();
      base.OnFormClosed(e);
    }
  }

  // Active monitors from QueryDisplayConfig, classified physical/virtual by connector technology and name.
  public static class Displays {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Lo; public int Hi; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] struct RATIONAL { public uint n; public uint d; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_TARGET { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling; public RATIONAL refreshRate; public uint scanLineOrdering; public bool targetAvailable; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_INFO { public PATH_SOURCE sourceInfo; public PATH_TARGET targetInfo; public uint flags; }
    [StructLayout(LayoutKind.Sequential)] struct MODE_INFO { public uint infoType; public uint id; public LUID adapterId; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 48)] public byte[] data; }
    [StructLayout(LayoutKind.Sequential)] struct HDR { public uint type; public uint size; public LUID adapterId; public uint id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct TNAME { public HDR header; public uint flags; public uint outputTechnology; public ushort edidManufactureId; public ushort edidProductCodeId; public uint connectorInstance; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string friendly; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string path; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SNAME { public HDR header; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string gdi; }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint f, ref uint np, [Out] PATH_INFO[] p, ref uint nm, [Out] MODE_INFO[] m, IntPtr t);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TNAME a);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SNAME a);
    delegate bool MonEnum(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr d);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MI { public int cb; public int l, t, r, b; public int wl, wt, wr, wb; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dev; }
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonEnum cb, IntPtr d);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr h, ref MI mi);

    // Real connectors: HD15, S-video, composite, component, DVI, HDMI, LVDS, D-JPN, SDI, DP ext/embedded,
    // UDI ext/embedded, SDTV dongle, internal. Miracast (15) and indirect wired/virtual (16/17) are not.
    static readonly HashSet<uint> Connectors = new HashSet<uint> { 0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 0x80000000 };

    public class Target { public string Gdi, Name, Path; public uint Tech; public bool Physical; }
    public static List<Target> Targets() {
      var r = new List<Target>(); uint np, nm;
      if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0) return r;
      var p = new PATH_INFO[np]; var m = new MODE_INFO[nm];
      if (QueryDisplayConfig(2, ref np, p, ref nm, m, IntPtr.Zero) != 0) return r;   // QDC_ONLY_ACTIVE_PATHS
      for (int i = 0; i < np; i++) {
        var t = new TNAME(); t.header.type = 2; t.header.size = (uint)Marshal.SizeOf(t); t.header.adapterId = p[i].targetInfo.adapterId; t.header.id = p[i].targetInfo.id; DisplayConfigGetDeviceInfo(ref t);
        var s = new SNAME(); s.header.type = 1; s.header.size = (uint)Marshal.SizeOf(s); s.header.adapterId = p[i].sourceInfo.adapterId; s.header.id = p[i].sourceInfo.id; DisplayConfigGetDeviceInfo(ref s);
        string id = ((t.friendly ?? "") + " " + (t.path ?? "")).ToLowerInvariant();
        bool virt = id.Contains("jump") || id.Contains("virtual") || id.Contains("idd") || id.Contains("parsec") || id.Contains("sudovda");
        r.Add(new Target { Gdi = s.gdi, Name = t.friendly, Path = t.path, Tech = p[i].targetInfo.outputTechnology,
                           Physical = Connectors.Contains(p[i].targetInfo.outputTechnology) && !virt });
      }
      return r;
    }
    // GDI device name -> desktop rectangle (physical pixels under per-monitor-v2 awareness), physical monitors only.
    // A GDI source cloned onto a physical and a virtual target counts as physical (the room would see it).
    public static Dictionary<string, Rectangle> Physical() {
      var phys = new HashSet<string>(Targets().Where(t => t.Physical).Select(t => t.Gdi));
      var r = new Dictionary<string, Rectangle>();
      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, dc, rc, d) => {
        var mi = new MI(); mi.cb = Marshal.SizeOf(mi);
        if (GetMonitorInfo(h, ref mi) && phys.Contains(mi.dev)) r[mi.dev] = Rectangle.FromLTRB(mi.l, mi.t, mi.r, mi.b);
        return true; }, IntPtr.Zero);
      return r;
    }
    public static string Signature(Dictionary<string, Rectangle> d) {
      return string.Join(" ", d.OrderBy(kv => kv.Key).Select(kv => kv.Key.Replace(@"\\.\", "") + "=" + kv.Value.Width + "x" + kv.Value.Height + "@" + kv.Value.X + "," + kv.Value.Y));
    }
  }

  public static class Native {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool LockWorkStation();
    public static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);
  }

  // DDC/CI brightness for external monitors (the laptop panel has no DDC; it goes through WMI instead).
  public static class Ddc {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PHYS { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc; }
    delegate bool MonEnum(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr d);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MI { public int cb; public int l, t, r, b; public int wl, wt, wr, wb; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dev; }
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonEnum cb, IntPtr d);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr h, ref MI mi);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
    [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYS[] a);
    [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr type, out uint cur, out uint max);
    [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PHYS[] a);

    static void ForEach(Action<string, IntPtr> f) {
      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, dc, rc, d) => {
        var mi = new MI(); mi.cb = Marshal.SizeOf(mi); GetMonitorInfo(h, ref mi);
        uint n; if (!GetNumberOfPhysicalMonitorsFromHMONITOR(h, out n) || n == 0) return true;
        var a = new PHYS[n];
        if (GetPhysicalMonitorsFromHMONITOR(h, n, a)) { foreach (var p in a) f(mi.dev, p.h); DestroyPhysicalMonitors(n, a); }
        return true; }, IntPtr.Zero);
    }
    // "\\.\DISPLAY2" -> current VCP value, for every monitor that answers.
    public static Dictionary<string, int> Get(byte code) {
      var r = new Dictionary<string, int>();
      ForEach((dev, h) => { uint cur, max; if (GetVCPFeatureAndVCPFeatureReply(h, code, IntPtr.Zero, out cur, out max)) r[dev] = (int)cur; });
      return r;
    }
    public static bool Set(string device, byte code, uint value) {
      bool ok = false;
      ForEach((dev, h) => { if (dev == device) ok = SetVCPFeature(h, code, value) || ok; });
      return ok;
    }
  }
}
