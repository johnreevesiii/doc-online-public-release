// DOC Host -- the one window for Derby Owners Club community hosts (doc-ops #117 Phase 1).
//
// Built with the C# compiler that ships inside Windows (.NET Framework 4.x, C# 5), so it needs no extra
// install, starts in well under a second and works offline. Every button runs one verb of
// hostapp\DocHostActions.ps1, which is built on the Host Pack's own setup\Common.ps1; the status lights are
// read here directly (process list, local ports, the broker's /api/health) every few seconds.
//
// Nothing in this file talks to a website except: the pairing flow (through DocHostActions.ps1, the same
// device-code endpoints SETUP - Start Here uses), the hub tunnel health check the pack's Doctor also makes,
// and opening the website in the browser when the host presses a website button.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("DOC Host")]
[assembly: System.Reflection.AssemblyProduct("DOC Host")]
[assembly: System.Reflection.AssemblyDescription("Derby Owners Club community host app")]
[assembly: System.Reflection.AssemblyVersion(DocHost.BuildInfo.AsmVersion)]
[assembly: System.Reflection.AssemblyFileVersion(DocHost.BuildInfo.AsmVersion)]
[assembly: System.Reflection.AssemblyInformationalVersion(DocHost.BuildInfo.Version)]

namespace DocHost
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            // Windowless launcher for the hosting scheduled tasks (2026-10-11). A task that runs powershell.exe
            // in the interactive session opens a console window, even with -WindowStyle Hidden, and hosts close
            // those windows on instinct, which killed the step (the restart listener's window never closed).
            // This exe is a GUI app, so the task opens no window; it starts PowerShell with no window and exits
            // at once, before the app mutex, so it never blocks an upgrade or the real window.
#if DOCHOST_TASKLAUNCHER
            // hostapp\DocHostTask.exe: the same launcher built alone (build_installer.py). Every scheduled task starts
            // through it. Only the full installer writes it, never an update, so a power cut while an update swaps
            // DOC Host.exe still leaves the tasks a program to start, and the update task undoes the swap (review of
            // PR #45). It never opens a window: without --hidden-run it exits with 2.
            Environment.Exit(HiddenRun.Start(Environment.CommandLine));
            return;
#else
            if (args.Length > 0 && (args[0] == "--hidden-run" || args[0] == "--hidden-run-wait"))
            {
                Environment.Exit(HiddenRun.Start(Environment.CommandLine));
                return;
            }
            bool created;
            // Also the installer's AppMutex: setup asks the host to close DOC Host before an upgrade.
#if DOCHOST_RELEASE
            Mutex m = new Mutex(true, "DOCHostApp", out created);
#else
            Mutex m = new Mutex(true, "DOCHostApp_Test", out created);   // a test build never blocks the real one
#endif
            if (!created)
            {
                MessageBox.Show("DOC Host is already open.", "DOC Host", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Tls.Setup();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm(args));
            GC.KeepAlive(m);
#endif
        }
    }

    // "DOC Host.exe" --hidden-run <powershell arguments>: everything after the flag goes to powershell.exe verbatim
    // (taken from the raw command line, so the task's own quoting reaches PowerShell unchanged).
    // "--hidden-run-wait" (the update task) stays until PowerShell ends and holds it in a job that is killed with
    // this process, so the task's time limit, Stop and "do not start a second copy" apply to the real updater.
    // Only that PowerShell is in the job: anything it starts breaks away silently (hosting is never killed).
    static class HiddenRun
    {
        // The marker must be the FIRST argument after the program path (a folder named "--hidden-run" in the
        // install path must not be mistaken for it). Returns null when absent.
        public static string PowerShellArgs(string commandLine, out bool wait)
        {
            wait = false;
            string s = commandLine.TrimStart(' ', '\t');
            int end;
            if (s.StartsWith("\"")) { end = s.IndexOf('"', 1); if (end < 0) return null; end++; }
            else { end = s.IndexOfAny(new[] { ' ', '\t' }); if (end < 0) return null; }
            string rest = s.Substring(end).TrimStart(' ', '\t');
            foreach (string m in new[] { "--hidden-run-wait", "--hidden-run" })
            {
                if (rest.StartsWith(m, StringComparison.Ordinal) && (rest.Length == m.Length || rest[m.Length] == ' ' || rest[m.Length] == '\t'))
                {
                    wait = m == "--hidden-run-wait";
                    return rest.Substring(m.Length).TrimStart(' ', '\t');
                }
            }
            return null;
        }
        public static string PowerShellArgs(string commandLine) { bool w; return PowerShellArgs(commandLine, out w); }

        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimit { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters { public ulong a, b, c, d, e, f; }
        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimit { public BasicLimit Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attrs, string name);
        [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimit info, int len);
        [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        const uint KILL_ON_JOB_CLOSE = 0x2000, SILENT_BREAKAWAY_OK = 0x1000;

        public static int Start(string commandLine)
        {
            bool wait;
            string a = PowerShellArgs(commandLine, out wait);
            if (string.IsNullOrEmpty(a)) return 2;
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(
                    Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"), a);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                psi.WorkingDirectory = Environment.SystemDirectory;
                if (!wait) { using (Process.Start(psi)) { } return 0; }
                IntPtr job = CreateJobObject(IntPtr.Zero, null);
                if (job != IntPtr.Zero)
                {
                    ExtendedLimit li = new ExtendedLimit();
                    li.Basic.LimitFlags = KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK;
                    if (!SetInformationJobObject(job, 9, ref li, Marshal.SizeOf(typeof(ExtendedLimit)))) { CloseHandle(job); job = IntPtr.Zero; }
                }
                using (Process p = Process.Start(psi))
                {
                    if (job != IntPtr.Zero) AssignProcessToJobObject(job, p.Handle);
                    p.WaitForExit();
                    return p.ExitCode;                      // the job handle closes with this process
                }
            }
            catch { return 1; }
        }
    }

    // TLS for every https call (the hub link check). Without this a csc-built .NET Framework exe offers only
    // SSL3/TLS 1.0, which the hub refuses. Always TLS 1.2. TLS 1.3 is added only on Windows builds whose
    // Schannel has it (Windows 11 / Server 2022, build 20348+): on Windows 10, asking .NET Framework for
    // TLS 1.3 can fail at connect time instead of falling back. If a handshake still fails with 1.3 on,
    // DropTls13() falls back to 1.2 alone for the rest of the session.
    static class Tls
    {
        public static bool Has13;
        static int WindowsBuild()
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    int b; if (k != null && int.TryParse(Convert.ToString(k.GetValue("CurrentBuildNumber")), out b)) return b;
                }
            }
            catch { }
            return 0;
        }
        public static void Setup()
        {
            SecurityProtocolType p = SecurityProtocolType.Tls12;
            if (WindowsBuild() >= 20348)
            {
                try { ServicePointManager.SecurityProtocol = p | (SecurityProtocolType)12288; Has13 = true; return; }
                catch (NotSupportedException) { }
            }
            ServicePointManager.SecurityProtocol = p;
        }
        public static bool DropTls13()
        {
            if (!Has13) return false;
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12; Has13 = false; return true;
        }
    }

    sealed class Paths
    {
        public string AppDir, PackRoot, ScriptDir, DataDir, Lobby, Hub, Broker;
        public bool Sandbox;

        public Paths()
        {
            AppDir = Path.GetDirectoryName(Application.ExecutablePath);
            ScriptDir = Path.Combine(AppDir, "hostapp");
            PackRoot = Path.Combine(AppDir, "pack");
#if DOCHOST_RELEASE
            Sandbox = false;     // release builds have no test hooks at all
#else
            Sandbox = Environment.GetEnvironmentVariable("DOCHOST_SANDBOX") == "1";
            string pk = Environment.GetEnvironmentVariable("DOCHOST_PACK");
            if (Sandbox && !string.IsNullOrEmpty(pk)) PackRoot = pk;
#endif
            // Per Windows user and private to it (the installer locks the folder): it holds the cabinet token.
#if DOCHOST_RELEASE
            DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"DOC Host\data");
#else
            DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"DOC Host TEST\data");
#endif
            string dd = Path.Combine(ScriptDir, "datadir.txt");
            try { if (File.Exists(dd)) { string t = File.ReadAllText(dd).Trim(); if (t.Length > 0) DataDir = t; } } catch { }
            Lobby = "https://play.johnreevesiii.com";
            Hub = "https://doc.johnreevesiii.com";
            Broker = "http://127.0.0.1:8770";
#if !DOCHOST_RELEASE
            if (Sandbox)
            {
                string stub = Environment.GetEnvironmentVariable("DOCHOST_STUB");
                if (!string.IsNullOrEmpty(stub)) { Lobby = stub.TrimEnd('/'); Hub = Lobby; }
                string hub = Environment.GetEnvironmentVariable("DOCHOST_HUB");
                if (!string.IsNullOrEmpty(hub)) Hub = hub.TrimEnd('/');
                string br = Environment.GetEnvironmentVariable("DOCHOST_BROKER");
                if (!string.IsNullOrEmpty(br)) Broker = br.TrimEnd('/');
                // Test builds only: the TLS test hub on 127.0.0.1 uses a throwaway self-signed certificate.
                ServicePointManager.ServerCertificateValidationCallback = delegate (object o, System.Security.Cryptography.X509Certificates.X509Certificate c,
                    System.Security.Cryptography.X509Certificates.X509Chain ch, System.Net.Security.SslPolicyErrors e)
                {
                    HttpWebRequest r = o as HttpWebRequest;
                    return e == System.Net.Security.SslPolicyErrors.None || (r != null && r.RequestUri.Host == "127.0.0.1");
                };
            }
#endif
        }
        public string LogsDir { get { return Path.Combine(DataDir, "logs"); } }
    }

    // One light: a coloured dot, a name and a short reason.
    sealed class Light
    {
        public Label Dot, Name, Text;
        public Light(Control parent, string name, int y)
        {
            Dot = new Label(); Dot.Text = "\u25CF"; Dot.Font = new Font("Segoe UI", 13f); Dot.AutoSize = true;
            Dot.Location = new Point(10, y - 4); Dot.ForeColor = Color.Gray;
            Name = new Label(); Name.Text = name; Name.AutoSize = true; Name.Location = new Point(34, y);
            Name.Font = new Font("Segoe UI", 9f, FontStyle.Bold);
            Text = new Label(); Text.Text = "checking..."; Text.AutoSize = false; Text.Location = new Point(150, y);
            Text.Size = new Size(260, 18); Text.AutoEllipsis = true;
            parent.Controls.Add(Dot); parent.Controls.Add(Name); parent.Controls.Add(Text);
        }
        public void Set(int level, string text)
        {
            // 0 off (grey), 1 good (green), 2 attention (amber), 3 problem (red)
            Color[] c = { Color.Gray, Color.FromArgb(0, 140, 60), Color.FromArgb(200, 130, 0), Color.FromArgb(200, 30, 30) };
            Dot.ForeColor = c[Math.Max(0, Math.Min(3, level))];
            Text.Text = text;
        }
    }

    sealed class Status
    {
        public bool Paired; public string CabLabel = "", CabId = ""; public int Seats; public string Rom = "";
        public bool BrokerAnswer, BrokerOurs; public string BrokerStore = "";
        public int Flycast, Stations, Feeds; public bool Agent, Recover, Input;
        public int LinkState; // 0 unknown, 1 ok, 2 not answering
        public List<int> LocalSeats = new List<int>();
        public string RecState = "", RecDetail = "";
    }

    sealed class MainForm : Form
    {
        readonly Paths P = new Paths();
        readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        Label lblTitle, lblCab, lblPairCode, lblNote;
        Button btnPair, btnSite, btnStart, btnStop, btnFix, btnRestart, btnDoctor, btnConsole, btnLogs, btnAdvanced;
        ComboBox cmbGame; NumericUpDown numSeats; CheckBox chkLocal, chkVideo, chkRemote;
        // updates (doc-ops #117 Phase 1, D-015)
        Label lblUpd; Button btnCheckUpd, btnApplyUpd; CheckBox chkAutoUpd; bool updAvailable, updConfigured; ToolTip updTip = new ToolTip();
        string updInstalled = "", updTask = ""; DateTime updStateTime = DateTime.MinValue;
        TextBox txtLog;
        Light lPaired, lBroker, lGame, lStations, lLink, lVideo, lRemote;
        List<string> romKeys = new List<string>();
        bool busy, loadingInfo = true;
        string siteRom = "";
        System.Windows.Forms.Timer uiTimer;
        Thread statusThread;
        volatile bool closing;
        DateTime lastLinkCheck = DateTime.MinValue; int lastLinkState;
        string appLog;

        public MainForm(string[] args)
        {
#if DOCHOST_RELEASE
            Text = "DOC Host";
#else
            Text = "DOC Host TEST build" + (P.Sandbox ? "  (sandbox)" : "");
#endif
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            ClientSize = new Size(760, 650);
            MinimumSize = new Size(776, 610);
            Font = new Font("Segoe UI", 9f);
            StartPosition = FormStartPosition.CenterScreen;
            appLog = Path.Combine(P.LogsDir, "dochost-app.log");
            Build();
            Shown += delegate { Log("DOC Host " + BuildInfo.Version + " (pack folder " + P.PackRoot + ", data " + P.DataDir + ")"); LoadInfo(); StartStatus(); };
            FormClosing += delegate { closing = true; };
        }

        Button Btn(Control parent, string text, int x, int y, int w, EventHandler click)
        {
            Button b = new Button(); b.Text = text; b.Location = new Point(x, y); b.Size = new Size(w, 30);
            b.Click += click; parent.Controls.Add(b); return b;
        }

        void Build()
        {
            lblTitle = new Label(); lblTitle.Text = "DOC Host"; lblTitle.Font = new Font("Segoe UI", 16f, FontStyle.Bold);
            lblTitle.AutoSize = true; lblTitle.Location = new Point(12, 8); Controls.Add(lblTitle);
            lblCab = new Label(); lblCab.AutoSize = false; lblCab.Location = new Point(14, 44); lblCab.Size = new Size(730, 20);
            lblCab.Text = "Reading this PC's cabinet..."; Controls.Add(lblCab);

            // ---- left: cabinet + game -------------------------------------------------------------
            GroupBox gCab = new GroupBox(); gCab.Text = "1. Sign in"; gCab.Location = new Point(12, 70); gCab.Size = new Size(320, 96); Controls.Add(gCab);
            btnPair = Btn(gCab, "Sign in and pair this PC", 10, 22, 190, delegate { DoPair(); });
            btnSite = Btn(gCab, "Open website", 206, 22, 104, delegate { OpenUrl(P.Lobby + "/stable"); });
            lblPairCode = new Label(); lblPairCode.AutoSize = false; lblPairCode.Location = new Point(10, 58); lblPairCode.Size = new Size(300, 34);
            lblPairCode.Text = "Pairing uses your Derby Owners Club account in the browser."; gCab.Controls.Add(lblPairCode);

            GroupBox gGame = new GroupBox(); gGame.Text = "2. Game and seats"; gGame.Location = new Point(12, 172); gGame.Size = new Size(320, 168); Controls.Add(gGame);
            Label lg = new Label(); lg.Text = "Game"; lg.AutoSize = true; lg.Location = new Point(10, 26); gGame.Controls.Add(lg);
            cmbGame = new ComboBox(); cmbGame.DropDownStyle = ComboBoxStyle.DropDownList; cmbGame.Location = new Point(60, 22); cmbGame.Size = new Size(250, 24);
            cmbGame.Items.Add("loading..."); cmbGame.SelectedIndex = 0; cmbGame.SelectedIndexChanged += delegate { UpdateNote(); }; gGame.Controls.Add(cmbGame);
            Label ls = new Label(); ls.Text = "Seats"; ls.AutoSize = true; ls.Location = new Point(10, 58); gGame.Controls.Add(ls);
            numSeats = new NumericUpDown(); numSeats.Minimum = 1; numSeats.Maximum = 8; numSeats.Value = 8; numSeats.Location = new Point(60, 55); numSeats.Size = new Size(50, 24); gGame.Controls.Add(numSeats);
            chkLocal = new CheckBox(); chkLocal.Text = "I will play at this PC too (keeps seat 1 for me)"; chkLocal.AutoSize = true; chkLocal.Location = new Point(10, 86); gGame.Controls.Add(chkLocal);
            chkVideo = new CheckBox(); chkVideo.Text = "Broadcast video so remote players can play"; chkVideo.AutoSize = true; chkVideo.Checked = true; chkVideo.Location = new Point(10, 110); gGame.Controls.Add(chkVideo);
            chkRemote = new CheckBox(); chkRemote.Text = "Let remote players restart and fix screens"; chkRemote.AutoSize = true; chkRemote.Checked = true; chkRemote.Location = new Point(10, 134);
            chkRemote.CheckedChanged += delegate { if (!loadingInfo) RunAction("SetOption", "-Name remote_recover -Value " + (chkRemote.Checked ? "1" : "0"), null, true); };
            gGame.Controls.Add(chkRemote);

            GroupBox gRun = new GroupBox(); gRun.Text = "3. Host"; gRun.Location = new Point(12, 346); gRun.Size = new Size(320, 62); Controls.Add(gRun);
            btnStart = Btn(gRun, "Start hosting", 10, 22, 145, delegate { DoStart(false); });
            btnStart.Font = new Font("Segoe UI", 9f, FontStyle.Bold);
            btnStop = Btn(gRun, "Stop hosting", 165, 22, 145, delegate { RunAction("Stop", "", null, false); });

            // ---- right: lights + tools -----------------------------------------------------------
            GroupBox gStat = new GroupBox(); gStat.Text = "Status"; gStat.Location = new Point(342, 70); gStat.Size = new Size(406, 196); Controls.Add(gStat);
            lPaired = new Light(gStat, "Paired", 24);
            lBroker = new Light(gStat, "Card broker", 48);
            lGame = new Light(gStat, "Game", 72);
            lStations = new Light(gStat, "Seat stations", 96);
            lLink = new Light(gStat, "Lobby link", 120);
            lVideo = new Light(gStat, "Video", 144);
            lRemote = new Light(gStat, "Remote restart", 168);

            GroupBox gTools = new GroupBox(); gTools.Text = "Fix and check"; gTools.Location = new Point(342, 272); gTools.Size = new Size(406, 136); Controls.Add(gTools);
            btnFix = Btn(gTools, "Fix picture", 10, 22, 125, delegate { RunAction("FixPicture", "", null, false); });
            btnRestart = Btn(gTools, "Restart game", 140, 22, 125, delegate {
                if (MessageBox.Show(this, "Restart the game windows? Anyone mid-race loses that race.", "DOC Host", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK)
                    RunAction("RestartGame", "", null, false);
            });
            btnDoctor = Btn(gTools, "Doctor", 270, 22, 125, delegate { RunAction("Doctor", "", null, false); });
            btnConsole = Btn(gTools, "Host Console", 10, 58, 125, delegate { OpenUrl(P.Broker + "/host"); });
            btnLogs = Btn(gTools, "Open logs", 140, 58, 125, delegate { OpenFolder(P.LogsDir); });
            btnAdvanced = Btn(gTools, "Advanced", 270, 58, 125, delegate { OpenFolder(Path.Combine(P.AppDir, "Advanced")); });
            lblNote = new Label(); lblNote.AutoSize = false; lblNote.Location = new Point(10, 94); lblNote.Size = new Size(388, 36);
            lblNote.ForeColor = Color.FromArgb(150, 90, 0); gTools.Controls.Add(lblNote);

            // ---- updates: signed, only changed files, installed when nobody is seated ----------------------
            GroupBox gUpd = new GroupBox(); gUpd.Text = "Updates"; gUpd.Location = new Point(12, 412); gUpd.Size = new Size(736, 50); Controls.Add(gUpd);
            lblUpd = new Label(); lblUpd.AutoSize = false; lblUpd.Location = new Point(10, 21); lblUpd.Size = new Size(250, 20);
            lblUpd.Text = "Checking..."; gUpd.Controls.Add(lblUpd);
            btnCheckUpd = Btn(gUpd, "Check for updates", 262, 16, 130, delegate { RunAction("CheckUpdate", "", null, false); });
            btnApplyUpd = Btn(gUpd, "Update now", 398, 16, 100, delegate { RunAction("ApplyUpdate", "", delegate { LoadInfo(); }, false); });
            chkAutoUpd = new CheckBox(); chkAutoUpd.Text = "Install automatically when nobody is seated"; chkAutoUpd.AutoSize = true;
            chkAutoUpd.Location = new Point(506, 20); chkAutoUpd.Checked = true;
            chkAutoUpd.CheckedChanged += delegate { if (!loadingInfo) RunAction("SetOption", "-Name update_mode -Value " + (chkAutoUpd.Checked ? "auto" : "ask"), null, true); };
            gUpd.Controls.Add(chkAutoUpd);

            txtLog = new TextBox(); txtLog.Multiline = true; txtLog.ReadOnly = true; txtLog.ScrollBars = ScrollBars.Vertical;
            txtLog.Location = new Point(12, 468); txtLog.Size = new Size(736, 170); txtLog.Font = new Font("Consolas", 8.5f);
            txtLog.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right; txtLog.BackColor = Color.White;
            Controls.Add(txtLog);

            uiTimer = new System.Windows.Forms.Timer(); uiTimer.Interval = 500; uiTimer.Tick += delegate { UpdateButtons(); }; uiTimer.Start();
        }

        // ---- log -----------------------------------------------------------------------------------
        void Log(string s)
        {
            if (s == null) return;
            string line = DateTime.Now.ToString("HH:mm:ss") + "  " + s;
            if (txtLog.TextLength > 200000) txtLog.Text = txtLog.Text.Substring(100000);
            txtLog.AppendText(line + "\r\n");
            AppendLog(DateTime.Now.ToString("o") + " " + s + "\r\n");
        }

        // Shared write, and a few short retries: someone reading the log (Notepad, a support script) must not
        // make the window drop a line.
        void AppendLog(string text)
        {
            byte[] b = Encoding.UTF8.GetBytes(text);
            for (int i = 0; i < 5; i++)
            {
                try
                {
                    Directory.CreateDirectory(P.LogsDir);
                    using (FileStream f = new FileStream(appLog, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                        f.Write(b, 0, b.Length);
                    return;
                }
                catch (IOException) { Thread.Sleep(40); }
                catch { return; }
            }
        }

        // ---- actions ---------------------------------------------------------------------------------
        static string PowerShellExe()
        {
            return Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        }

        void RunAction(string verb, string extra, Action<int> done, bool quiet)
        {
            if (busy && !quiet) { Log("Please wait: another step is still running."); return; }
            string script = Path.Combine(P.ScriptDir, "DocHostActions.ps1");
            ProcessStartInfo psi = new ProcessStartInfo(PowerShellExe(),
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\" -Action " + verb + (extra.Length > 0 ? " " + extra : ""));
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
            psi.WorkingDirectory = Directory.Exists(P.PackRoot) ? P.PackRoot : P.AppDir;
            Process p = new Process(); p.StartInfo = psi; p.EnableRaisingEvents = true;
            if (!quiet) { busy = true; Log("> " + Pretty(verb)); }
            p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) Ui(delegate { OnLine(e.Data, quiet); }); };
            p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null && e.Data.Trim().Length > 0) Ui(delegate { if (!quiet) Log("  " + e.Data); }); };
            p.Exited += delegate
            {
                int code = -1; try { p.WaitForExit(); code = p.ExitCode; } catch { }
                Ui(delegate
                {
                    if (!quiet) { busy = false; Log(Pretty(verb) + (code == 0 ? ": done" : ": finished with code " + code)); }
                    if (done != null) done(code);
                });
            };
            try { p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine(); }
            catch (Exception ex) { busy = false; Log("Could not run PowerShell: " + ex.Message); }
        }

        static string Pretty(string verb)
        {
            switch (verb)
            {
                case "Pair": return "Sign in and pair";
                case "Start": return "Start hosting";
                case "Stop": return "Stop hosting";
                case "FixPicture": return "Fix picture";
                case "RestartGame": return "Restart game";
                case "Doctor": return "Doctor";
                case "Info": return "Read settings";
                default: return verb;
            }
        }

        void Ui(MethodInvoker a) { if (closing) return; try { if (IsHandleCreated) BeginInvoke(a); } catch { } }

        void OnLine(string line, bool quiet)
        {
            if (line.StartsWith("@@"))
            {
                int sp = line.IndexOf(' ');
                string tag = sp > 2 ? line.Substring(2, sp - 2) : line.Substring(2);
                string json = sp > 0 ? line.Substring(sp + 1) : "{}";
                Dictionary<string, object> o = null;
                try { o = Json.Deserialize<Dictionary<string, object>>(json); } catch { }
                if (o == null) return;
                if (tag == "INFO") ApplyInfo(o);
                else if (tag == "PAIRCODE") lblPairCode.Text = "Code " + S(o, "code") + ": approve it in the browser that opened (or go to " + S(o, "uri") + ").";
                else if (tag == "NEEDFORCE") pendingForce = o;
                else if (tag == "SITEROM") { siteRom = S(o, "site"); UpdateNote(); }
                else if (tag == "UPDATE") ShowUpdate(o, null);
                return;
            }
            if (!quiet) Log("  " + line);
        }

        Dictionary<string, object> pendingForce;

        // The update line: installed version and what the last check found. Notes are shown as plain text only.
        void ShowUpdate(Dictionary<string, object> st, string installed)
        {
            string status = S(st, "status");
            string inst = installed ?? S(st, "installed");
            if (inst.Length > 0) updInstalled = inst; else inst = updInstalled;
            updAvailable = status == "available" || status == "waiting" || status == "failed";
            string t;
            if (!updConfigured) t = "Version " + inst + ". Updates are not set up yet.";
            else if (status == "available" || status == "waiting")
            {
                long bytes = 0; long.TryParse(S(st, "bytes"), out bytes);
                t = "Update " + S(st, "version") + " ready (" + S(st, "files") + " file(s), " + (bytes / 1024 + 1) + " KB)"
                    + (status == "waiting" ? ": waits, " + S(st, "why") : "");
            }
            else if (status == "updated") t = "Updated to " + inst + (S(st, "reopen") == "True" ? ". Reopen DOC Host to finish." : ".");
            else if (status == "rolled_back") t = "Update " + S(st, "version") + " did not start cleanly: rolled back to " + inst + ".";
            else if (status == "refused") t = "Update refused (failed the signature or safety checks).";
            else if (status == "failed") t = "Update " + S(st, "version") + " failed here and was undone. Update now retries it.";
            else if (status == "current") t = "Version " + inst + ". Up to date.";
            else if (status == "off") t = "Version " + inst + ". Updates are off on this PC: " + S(st, "why") + ".";
            else t = "Version " + inst + ". Not checked yet.";
            if (updConfigured && updTask == "failed") t += " (Automatic checks could not be scheduled: reopen DOC Host to retry.)";
            lblUpd.Text = t;
            updTip.SetToolTip(lblUpd, S(st, "notes"));   // plain text; one tooltip, replaced each time
        }

        static string S(Dictionary<string, object> o, string k)
        {
            object v; if (o != null && o.TryGetValue(k, out v) && v != null) return Convert.ToString(v); return "";
        }

        void LoadInfo()
        {
            loadingInfo = true;
            RunAction("Info", "", delegate (int code) { loadingInfo = false; if (code != 0) Log("Could not read the pack settings (code " + code + ")."); }, true);
        }

        void ApplyInfo(Dictionary<string, object> o)
        {
            loadingInfo = true;
            try
            {
                lblTitle.Text = "DOC Host " + S(o, "pack_version") + (P.Sandbox ? "  (sandbox)" : "");
                cmbGame.Items.Clear(); romKeys.Clear();
                ArrayList games = o.ContainsKey("games") ? o["games"] as ArrayList : null;
                if (games != null)
                    foreach (object g in games)
                    {
                        Dictionary<string, object> d = g as Dictionary<string, object>;
                        cmbGame.Items.Add(S(d, "key") + ") " + S(d, "name")); romKeys.Add(S(d, "rom"));
                    }
                Dictionary<string, object> upd = o.ContainsKey("update") ? o["update"] as Dictionary<string, object> : null;
                if (upd != null)
                {
                    updConfigured = S(upd, "configured") == "True";
                    updTask = S(upd, "task");
                    chkAutoUpd.Checked = S(upd, "mode") != "ask";
                    Dictionary<string, object> ust = upd.ContainsKey("state") ? upd["state"] as Dictionary<string, object> : null;
                    ShowUpdate(ust ?? new Dictionary<string, object>(), S(upd, "installed"));
                }
                Dictionary<string, object> st = o.ContainsKey("settings") ? o["settings"] as Dictionary<string, object> : null;
                if (st != null)
                {
                    chkRemote.Checked = S(st, "remote_recover") != "False";
                    chkVideo.Checked = S(st, "video") != "False";
                    siteRom = S(st, "site_rom");
                }
                Dictionary<string, object> cab = o.ContainsKey("cabinet") ? o["cabinet"] as Dictionary<string, object> : null;
                bool paired = S(o, "paired") == "True";
                string rom = cab != null ? S(cab, "rom") : "";
                int idx = romKeys.IndexOf(rom);
                if (idx < 0) idx = 0;
                if (cmbGame.Items.Count > 0) cmbGame.SelectedIndex = Math.Max(0, idx);
                if (cab != null)
                {
                    int seats; if (int.TryParse(S(cab, "seats"), out seats) && seats >= 1 && seats <= 8) numSeats.Value = seats;
                    ArrayList ls = cab.ContainsKey("local_seats") ? cab["local_seats"] as ArrayList : null;
                    chkLocal.Checked = ls != null && ls.Count > 0;
                }
                if (paired)
                {
                    lblCab.Text = "This PC is cabinet \"" + S(cab, "label") + "\" (" + S(cab, "id") + ").";
                    btnPair.Text = "Paired";
                    lblPairCode.Text = "Paired. Your cabinet's game version is set on the website (Stable, Host section).";
                }
                else
                {
                    lblCab.Text = "Not paired yet. Press Sign in and pair this PC.";
                    btnPair.Text = "Sign in and pair this PC";
                }
                paired_ = paired;
                int mig; int.TryParse(S(o, "migrated_pending_saves"), out mig);
                int migCards; int.TryParse(S(o, "migrated_cards"), out migCards);
                ArrayList foreign = o.ContainsKey("foreign_tasks") ? o["foreign_tasks"] as ArrayList : null;
                notes.Clear();
                if (mig > 0) notes.Add(mig + " unsaved horse" + (mig == 1 ? "" : "s") + " came over from your old pack. Tell the operator (data folder, migrated).");
                if (migCards > 0) notes.Add(migCards + " card" + (migCards == 1 ? "" : "s") + " from your old pack's seats and card libraries " + (migCards == 1 ? "was" : "were") + " copied for review. Tell the operator.");
                if (S(o, "legacy_data").Length > 0) notes.Add("The old shared folder " + S(o, "legacy_data") + " is no longer used; you can delete it after checking DOC Host.");
                if (S(o, "data_private") == "False") notes.Add("Warning: the data folder is not private to your Windows account. Reinstall DOC Host.");
                if (foreign != null && foreign.Count > 0) notes.Add("Another DOC pack folder on this PC owns the hosting tasks. Stop hosting there before you start here.");
                UpdateNote();
            }
            finally { loadingInfo = false; }
        }

        bool paired_;
        List<string> notes = new List<string>();

        void UpdateNote()
        {
            List<string> n = new List<string>(notes);
            string rom = SelectedRom();
            if (paired_ && siteRom.Length > 0 && rom.Length > 0 && siteRom != rom)
                n.Add("The website lists this cabinet as " + siteRom + ". Set it to " + rom + " there too (Open website).");
            if (lblNote != null) lblNote.Text = string.Join(" ", n.ToArray());
        }

        string SelectedRom()
        {
            int i = cmbGame.SelectedIndex; return (i >= 0 && i < romKeys.Count) ? romKeys[i] : "";
        }

        void DoPair()
        {
            if (paired_) { OpenUrl(P.Lobby + "/stable"); return; }
            string label = Environment.MachineName;
            RunAction("Pair", "-Label \"" + label.Replace("\"", "") + "\" -Seats " + (int)numSeats.Value, delegate { LoadInfo(); }, false);
        }

        void DoStart(bool force)
        {
            if (!paired_) { Log("Sign in and pair this PC first."); return; }
            string rom = SelectedRom();
            if (rom.Length == 0) { Log("Pick a game first."); return; }
            string a = "-Rom " + rom + " -Seats " + (int)numSeats.Value + (chkLocal.Checked ? " -LocalPlay" : "") + (chkVideo.Checked ? "" : " -NoVideo") + (force ? " -Force" : "");
            pendingForce = null;
            RunAction("Start", a, delegate (int code)
            {
                if (code == 3 && pendingForce != null)
                {
                    string msg = "Another Derby Owners Club pack folder on this PC owns the hosting tasks:\r\n\r\n";
                    ArrayList t = pendingForce.ContainsKey("tasks") ? pendingForce["tasks"] as ArrayList : null;
                    if (t != null) foreach (object x in t) msg += "  " + x + "\r\n";
                    msg += "\r\nOnly one pack can host at a time. Run Stop Hosting in that folder first.\r\nMake DOC Host the one that hosts on this PC now?";
                    if (MessageBox.Show(this, msg, "DOC Host", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.Yes)
                        DoStart(true);
                }
                LoadInfo();
            }, false);
        }

        void OpenUrl(string url)
        {
            if (P.Sandbox) { Log("sandbox: would open " + url); return; }
            try { Process.Start(url); } catch (Exception ex) { Log("Could not open " + url + ": " + ex.Message); }
        }

        void OpenFolder(string dir)
        {
            try { Directory.CreateDirectory(dir); } catch { }
            if (P.Sandbox && Environment.GetEnvironmentVariable("DOCHOST_NO_EXPLORER") == "1") { Log("sandbox: would open folder " + dir); return; }
            try { Process.Start("explorer.exe", "\"" + dir + "\""); } catch (Exception ex) { Log("Could not open " + dir + ": " + ex.Message); }
        }

        void UpdateButtons()
        {
            bool b = busy;
            btnPair.Enabled = !b; btnStart.Enabled = !b && paired_; btnStop.Enabled = !b;
            btnFix.Enabled = !b && paired_; btnRestart.Enabled = !b && paired_; btnDoctor.Enabled = !b;
            cmbGame.Enabled = !b; numSeats.Enabled = !b; chkLocal.Enabled = !b; chkVideo.Enabled = !b;
            btnCheckUpd.Enabled = !b && updConfigured && paired_; btnApplyUpd.Enabled = !b && updConfigured && paired_ && updAvailable;
            chkAutoUpd.Enabled = updConfigured;
            btnStart.Text = (lastStatus != null && lastStatus.Flycast > 0) ? "Apply and restart" : "Start hosting";
        }

        // ---- status lights (background thread) --------------------------------------------------------
        Status lastStatus;

        void StartStatus()
        {
            statusThread = new Thread(delegate ()
            {
                while (!closing)
                {
                    Status s = null;
                    try { s = ReadStatus(); } catch { }
                    if (s != null) Ui(delegate { ShowStatus(s); });
                    try
                    {
                        // a background update (the 30-minute task) writes update-state.json: show it without a restart
                        string sf = Path.Combine(P.DataDir, "updates", "update-state.json");
                        if (File.Exists(sf) && File.GetLastWriteTimeUtc(sf) > updStateTime)
                        {
                            updStateTime = File.GetLastWriteTimeUtc(sf);
                            Dictionary<string, object> us = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(sf));
                            if (us != null) Ui(delegate { ShowUpdate(us, null); });
                        }
                    }
                    catch { }
                    for (int i = 0; i < 8 && !closing; i++) Thread.Sleep(500);
                }
            });
            statusThread.IsBackground = true; statusThread.Start();
        }

        Status ReadStatus()
        {
            Status s = new Status();
            string cabPath = Path.Combine(P.PackRoot, "cabinet.json");
            try
            {
                if (File.Exists(cabPath))
                {
                    Dictionary<string, object> c = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(cabPath));
                    s.CabId = S(c, "id"); s.CabLabel = S(c, "label"); s.Rom = S(c, "rom_ver");
                    string tok = S(c, "host_token");
                    s.Paired = s.CabId.Length > 0 && tok.Length > 0 && tok.IndexOf("PASTE") < 0;
                    int.TryParse(S(c, "seat_count"), out s.Seats);
                }
            }
            catch { }
            if (s.Seats < 1 || s.Seats > 8) s.Seats = 4;
            try
            {
                string rs = Path.Combine(P.DataDir, "recover-status.json");
                if (File.Exists(rs))
                {
                    Dictionary<string, object> r = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(rs));
                    s.RecState = S(r, "state"); s.RecDetail = S(r, "detail");
                }
            }
            catch { }

            string rootDir = P.PackRoot.TrimEnd('\\') + "\\";
            string recScript = Path.Combine(P.ScriptDir, "DocHostRecover.ps1");
            try
            {
                using (ManagementObjectSearcher q = new ManagementObjectSearcher(
                    "SELECT ProcessId, Name, CommandLine, ExecutablePath FROM Win32_Process WHERE Name='python.exe' OR Name='flycast.exe' OR Name='powershell.exe'"))
                {
                    foreach (ManagementObject mo in q.Get())
                    {
                        string name = Convert.ToString(mo["Name"]) ?? "";
                        string cl = Convert.ToString(mo["CommandLine"]) ?? "";
                        string exe = Convert.ToString(mo["ExecutablePath"]) ?? "";
                        string both = cl + "|" + exe;
                        if (name.Equals("powershell.exe", StringComparison.OrdinalIgnoreCase))
                        {
                            if (cl.IndexOf(recScript, StringComparison.OrdinalIgnoreCase) >= 0) s.Recover = true;
                            continue;
                        }
                        if (both.IndexOf(rootDir, StringComparison.OrdinalIgnoreCase) < 0) continue;
                        if (name.Equals("flycast.exe", StringComparison.OrdinalIgnoreCase)) { s.Flycast++; continue; }
                        if (cl.IndexOf(rootDir + "broker.py", StringComparison.OrdinalIgnoreCase) >= 0) s.BrokerOurs = true;
                        else if (cl.IndexOf("relay_agent.py", StringComparison.OrdinalIgnoreCase) >= 0) s.Agent = true;
                        else if (cl.IndexOf("input_service.py", StringComparison.OrdinalIgnoreCase) >= 0) s.Input = true;
                        else if (cl.IndexOf("wgc_relay_push.py", StringComparison.OrdinalIgnoreCase) >= 0) s.Feeds++;
                    }
                }
            }
            catch { }

            try
            {
                HttpWebRequest r = (HttpWebRequest)WebRequest.Create(P.Broker + "/api/health");
                r.Timeout = 2500; r.ReadWriteTimeout = 2500; r.Proxy = null;
                using (HttpWebResponse resp = (HttpWebResponse)r.GetResponse())
                using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
                {
                    Dictionary<string, object> h = Json.Deserialize<Dictionary<string, object>>(sr.ReadToEnd());
                    s.BrokerAnswer = S(h, "ok") == "True"; s.BrokerStore = S(h, "store");
                    Dictionary<string, object> f = h.ContainsKey("flags") ? h["flags"] as Dictionary<string, object> : null;
                    ArrayList ls = f != null && f.ContainsKey("local_seats") ? f["local_seats"] as ArrayList : null;
                    if (ls != null) foreach (object x in ls) s.LocalSeats.Add(Convert.ToInt32(x));
                }
            }
            catch { }

            try
            {
                HashSet<int> listen = new HashSet<int>();
                foreach (IPEndPoint ep in IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners()) listen.Add(ep.Port);
                for (int i = 0; i < s.Seats; i++) if (listen.Contains(8788 + i)) s.Stations++;
            }
            catch { }

            // The hub tunnel check (the same one the pack's Doctor makes), at most every 30 s and only while
            // this install's relay agent runs.
            if (s.Paired && s.Agent)
            {
                if ((DateTime.UtcNow - lastLinkCheck).TotalSeconds >= 30)
                {
                    lastLinkCheck = DateTime.UtcNow;
                    lastLinkState = 2;
                    for (int attempt = 0; attempt < 2; attempt++)
                    {
                        try
                        {
                            HttpWebRequest r = (HttpWebRequest)WebRequest.Create(P.Hub + "/hub/cab_" + s.CabId + "/api/health");
                            r.Timeout = 8000; r.ReadWriteTimeout = 8000;
                            using (HttpWebResponse resp = (HttpWebResponse)r.GetResponse())
                            using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
                            {
                                Dictionary<string, object> h = Json.Deserialize<Dictionary<string, object>>(sr.ReadToEnd());
                                if (S(h, "ok") == "True") lastLinkState = 1;
                            }
                            break;
                        }
                        catch (WebException we)
                        {
                            bool tlsFail = we.Status == WebExceptionStatus.SecureChannelFailure || we.Status == WebExceptionStatus.SendFailure;
                            if (!(tlsFail && Tls.DropTls13())) break;
                        }
                        catch { break; }
                    }
                }
                s.LinkState = lastLinkState;
            }
            else { lastLinkCheck = DateTime.MinValue; s.LinkState = 0; }
            return s;
        }

        void ShowStatus(Status s)
        {
            lastStatus = s;
            bool hosting = s.Flycast > 0 || s.BrokerOurs || s.Agent;
            if (s.Paired) lPaired.Set(1, s.CabLabel + " (" + s.CabId + ")"); else lPaired.Set(3, "not paired: press Sign in");
            if (s.BrokerAnswer && s.BrokerOurs) lBroker.Set(1, "healthy (" + s.BrokerStore + ")");
            else if (s.BrokerAnswer && !s.BrokerOurs) lBroker.Set(2, "port 8770 is used by another DOC install");
            else if (s.BrokerOurs) lBroker.Set(3, "running but not answering");
            else lBroker.Set(hosting ? 3 : 0, hosting ? "down: press Doctor" : "off");
            if (s.Flycast > 0) lGame.Set(1, s.Flycast + " game window(s), " + GameName(s.Rom)); else lGame.Set(hosting ? 3 : 0, hosting ? "not running: press Restart game" : "off");
            if (s.Stations >= s.Seats) lStations.Set(1, s.Stations + " of " + s.Seats + " listening");
            else if (s.Stations > 0) lStations.Set(2, s.Stations + " of " + s.Seats + " listening");
            else lStations.Set(hosting ? 3 : 0, hosting ? "none listening" : "off");
            if (s.LinkState == 1) lLink.Set(1, "the lobby reaches this cabinet");
            else if (s.LinkState == 2) lLink.Set(2, "relay agent running, hub not answering yet");
            else lLink.Set(hosting ? 3 : 0, hosting ? (s.Agent ? "checking..." : "relay agent not running") : "off");
            if (!chkVideo.Checked) lVideo.Set(0, "video off (local play only)");
            else if (s.Feeds > 0) lVideo.Set(1, s.Feeds + " feed(s) publishing");
            else lVideo.Set(hosting ? 2 : 0, hosting ? "no feeds: press Fix picture" : "off");
            if (s.RecState == "token-refused") lRemote.Set(3, "stopped: the website refused this cabinet's token");
            else if (s.RecState == "house-cabinet") lRemote.Set(2, "stopped: the website treats this as a house cabinet");
            else if (!chkRemote.Checked) lRemote.Set(0, "off: the lobby does not offer restarts here");
            else if (s.Recover && s.RecState == "site-not-ready") lRemote.Set(2, "waiting: the website does not offer it yet");
            else if (s.Recover && s.RecState == "offline") lRemote.Set(2, "cannot reach the website");
            else if (s.Recover) lRemote.Set(1, "listening" + (s.LocalSeats.Count > 0 ? " (paused while you hold a seat)" : ""));
            else lRemote.Set(hosting ? 2 : 0, hosting ? "listener not running" : "starts with hosting");
        }

        string GameName(string rom)
        {
            int i = romKeys.IndexOf(rom);
            if (i >= 0 && i < cmbGame.Items.Count) { string t = Convert.ToString(cmbGame.Items[i]); int p = t.IndexOf(") "); return p > 0 ? t.Substring(p + 2) : t; }
            return rom;
        }
    }
}
