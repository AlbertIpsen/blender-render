// BlenderRender PC: the Windows side of BlenderRender, in the taskbar corner.
//
// Downloaded from GitHub (or a Mac's Add PC page), it sets the PC up (one admin prompt): the render
// queue and rqnet.py, which lets Macs with BlenderRender on the network find the PC and send it jobs.
// After that it starts at logon and has one switch: allow render jobs, or not. Switched off, rq.py
// starts nothing new (see `rq off` there); Macs hand split work to other computers. It keeps itself
// and the queue scripts it carries up to date from the public releases on GitHub.
//
// A Mac's Add PC page appends its filled-in setup script (with the Mac's SSH key and pairing link) to
// the exe it serves: script bytes, their length as a 4-byte little-endian int, then the 8 bytes
// "BRSETUP1". Without it, the app uses the setup script it carries, which skips SSH.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace BlenderRenderPC
{
    static class Paths
    {
        public const string Root = @"C:\GeysierRender";
        public const string Queue = Root + @"\queue";
        public const string RqCmd = Queue + @"\rq.cmd";
        public const string RqPy = Queue + @"\rq.py";
        public const string Installed = Queue + @"\BlenderRenderPC.exe";
        public const string TrayTask = "BlenderRenderPC";
    }

    static class Program
    {
        static Mutex single;
        static EventWaitHandle showSignal;

        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            single = new Mutex(false, @"Local\BlenderRenderPC");
            showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\BlenderRenderPC.Show");
            // An update restarts the app; give the old copy a moment to let go.
            bool restarted = args.Contains("--restarted");
            if (!single.WaitOne(restarted ? 10000 : 0))
            {
                showSignal.Set();  // already running: bring its window forward instead
                return;
            }
            var app = new TrayApp(showFirst: !args.Contains("--tray"));
            new Thread(() => { while (showSignal.WaitOne()) app.ShowWindowFromAnyThread(); }) { IsBackground = true }.Start();
            Application.Run(app);
            single.ReleaseMutex();
        }

        /// Set up from a Mac's Add PC page: its script, with SSH and pairing.
        public static bool FromMac => MacScript() != null;

        /// The setup script: the Mac's, appended to this exe, or the one this app carries.
        public static string EmbeddedScript() => MacScript() ?? Resource("setup.ps1");

        static readonly string[] Scripts = { "rq.py", "rqnet.py", "render_job.py", "remote_gpu.py", "progress.py" };

        public static string Resource(string name)
        {
            using (var s = typeof(Program).Assembly.GetManifestResourceStream(name))
            using (var r = new StreamReader(s ?? Stream.Null, Encoding.UTF8))
                return s == null ? null : r.ReadToEnd();
        }

        /// The queue scripts this app carries, written into `dir`.
        public static void ExtractScripts(string dir)
        {
            Directory.CreateDirectory(dir);
            foreach (var name in Scripts)
                File.WriteAllText(Path.Combine(dir, name), Resource("pc/" + name), new UTF8Encoding(false));
        }

        /// rq.py's VERSION line, 0 when there's none.
        public static int RqVersion(string text)
        {
            var m = System.Text.RegularExpressions.Regex.Match(text ?? "", @"^VERSION = (\d+)", System.Text.RegularExpressions.RegexOptions.Multiline);
            return m.Success ? int.Parse(m.Groups[1].Value) : 0;
        }

        static string MacScript()
        {
            try
            {
                var bytes = File.ReadAllBytes(Application.ExecutablePath);
                var magic = Encoding.ASCII.GetBytes("BRSETUP1");
                int n = bytes.Length;
                if (n < 12 || !bytes.Skip(n - 8).SequenceEqual(magic)) return null;
                int len = BitConverter.ToInt32(bytes, n - 12);
                if (len <= 0 || len > n - 12) return null;
                return Encoding.UTF8.GetString(bytes, n - 12 - len, len);
            }
            catch { return null; }
        }

        public static Icon AppIcon(int size)
        {
            using (var s = typeof(Program).Assembly.GetManifestResourceStream("AppIcon.ico"))
                return new Icon(s, size, size);
        }
    }

    /// What `rq list` says, boiled down for the window and the tray tooltip.
    class QueueState
    {
        public bool Off, Worker, Reachable, Paused;
        public string Error;
        public Dictionary<string, object> Rendering;
        public int Waiting;

        public static QueueState Read()
        {
            var q = new QueueState();
            try
            {
                var text = Rq.Run("list", 20000);
                var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(text);
                q.Reachable = true;
                q.Off = data.TryGetValue("off", out var off) && off is bool b && b;
                q.Worker = data.TryGetValue("worker", out var w) && w is bool wb && wb;
                q.Paused = data.TryGetValue("paused", out var pz) && pz is bool pb && pb;
                foreach (Dictionary<string, object> job in ((System.Collections.ArrayList)data["jobs"]))
                {
                    var state = job.TryGetValue("state", out var s) ? s as string : null;
                    if (state == "rendering") q.Rendering = job;
                    else if (state == "queued") q.Waiting++;
                }
            }
            catch (Exception e) { q.Error = e.Message; }
            return q;
        }

        static string Str(Dictionary<string, object> j, string k) => j != null && j.TryGetValue(k, out var v) && v != null ? Convert.ToString(v) : null;
        static double Num(Dictionary<string, object> j, string k) => j != null && j.TryGetValue(k, out var v) && v != null ? Convert.ToDouble(v) : 0;

        public double Progress => Num(Rendering, "progress");

        /// "Rendering Wall_1080p60" / "Rendering frames 120–155 of Wall_1080p60 (split job)"
        public string Headline
        {
            get
            {
                if (!Reachable) return "Waiting for the Mac to connect";
                if (Rendering != null)
                {
                    var name = Str(Rendering, "name") ?? "a job";
                    return Str(Rendering, "parent") != null
                        ? $"Rendering frames {Str(Rendering, "start")}–{Str(Rendering, "end")} of {name} (split job)"
                        : $"Rendering {name}";
                }
                return Paused ? "Paused from the Mac" : Off ? "Switched off" : "Ready for render jobs";
            }
        }

        public string Detail
        {
            get
            {
                var parts = new List<string>();
                if (Rendering != null)
                {
                    parts.Add($"{(int)(Progress * 100)}%");
                    var frame = Str(Rendering, "frame");
                    if (frame != null && Str(Rendering, "mode") == "animation") parts.Add("frame " + frame);
                    if (Paused) parts.Add("paused from the Mac");
                    if (Off) parts.Add("switches off when this is done");
                }
                else if (Paused) parts.Add("Rendering carries on when you choose Resume All on the Mac.");
                else if (Off) parts.Add("Jobs from the Mac wait until you switch this on.");
                if (Waiting > 0) parts.Add($"{Waiting} waiting");
                if (!Reachable) parts.Add("The Mac installs the render queue the first time it connects.");
                return string.Join(" · ", parts);
            }
        }
    }

    /// Runs rq.cmd (Blender's Python on rq.py) without a console window.
    static class Rq
    {
        public static bool Installed => File.Exists(Paths.RqCmd) && File.Exists(Paths.RqPy);

        public static string Run(string args, int timeoutMs)
        {
            if (!Installed) throw new InvalidOperationException("The render queue isn't installed yet.");
            var psi = new ProcessStartInfo("cmd.exe", $"/c \"\"{Paths.RqCmd}\" {args}\"")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
                RedirectStandardError = true, WorkingDirectory = Paths.Queue,
            };
            using (var p = Process.Start(psi))
            {
                var output = p.StandardOutput.ReadToEndAsync();
                var errors = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } throw new TimeoutException("rq " + args + " didn't answer."); }
                if (p.ExitCode != 0) throw new Exception(errors.Result.Trim().Length > 0 ? errors.Result.Trim() : "rq " + args + " failed.");
                return output.Result;
            }
        }
    }

    class TrayApp : ApplicationContext
    {
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ToolStripMenuItem statusItem = new ToolStripMenuItem { Enabled = false };
        readonly ToolStripMenuItem onItem = new ToolStripMenuItem("Allow render jobs");
        readonly Icon onIcon, offIcon;
        readonly MainWindow window;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 3000 };
        readonly System.Windows.Forms.Timer updateTimer = new System.Windows.Forms.Timer { Interval = 30000 };
        readonly DateTime startedFrom = File.Exists(Paths.Installed) ? File.GetLastWriteTimeUtc(Paths.Installed) : DateTime.MinValue;
        readonly bool runningInstalled = string.Equals(Path.GetFullPath(Application.ExecutablePath), Paths.Installed, StringComparison.OrdinalIgnoreCase);
        QueueState last;
        bool polling;

        public TrayApp(bool showFirst)
        {
            onIcon = Program.AppIcon(SystemInformation.SmallIconSize.Width);
            offIcon = Grey(onIcon);
            window = new MainWindow(this);
            _ = window.Handle;  // so another launch can bring the window forward before it was ever shown
            onItem.Click += (s, e) => SetOn(!onItem.Checked);
            var menu = new ContextMenuStrip();
            menu.Items.Add(statusItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(onItem);
            menu.Items.Add("Open BlenderRender PC", null, (s, e) => ShowWindow());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit", null, (s, e) => Quit());
            tray.ContextMenuStrip = menu;
            tray.Icon = onIcon;
            tray.Text = "BlenderRender PC";
            tray.Visible = true;
            tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) ShowWindow(); };
            timer.Tick += (s, e) => { Refresh(); CheckForUpdate(); };
            timer.Start();
            if (runningInstalled)
            {
                // Newer queue scripts this copy carries, then a newer copy of the app on GitHub: now and every 6 hours.
                updateTimer.Tick += (s, e) => { updateTimer.Interval = 6 * 3600 * 1000; Task.Run(() => SelfUpdate.Run()); };
                updateTimer.Start();
            }
            Refresh();
            // Not set up yet, or opened by hand: show the window. At logon (--tray) stay in the corner.
            if (showFirst || !Rq.Installed) ShowWindow();
        }

        public QueueState Last => last;

        static Icon Grey(Icon icon)
        {
            using (var bmp = icon.ToBitmap())
            using (var grey = new Bitmap(bmp.Width, bmp.Height))
            {
                using (var g = Graphics.FromImage(grey))
                {
                    var m = new System.Drawing.Imaging.ColorMatrix(new[] {
                        new float[] { .3f, .3f, .3f, 0, 0 }, new float[] { .59f, .59f, .59f, 0, 0 },
                        new float[] { .11f, .11f, .11f, 0, 0 }, new float[] { 0, 0, 0, .55f, 0 }, new float[] { 0, 0, 0, 0, 1 } });
                    var attrs = new System.Drawing.Imaging.ImageAttributes();
                    attrs.SetColorMatrix(m);
                    g.DrawImage(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height), 0, 0, bmp.Width, bmp.Height, GraphicsUnit.Pixel, attrs);
                }
                return Icon.FromHandle(grey.GetHicon());
            }
        }

        public void ShowWindowFromAnyThread()
        {
            if (window.IsHandleCreated) window.BeginInvoke((Action)ShowWindow);
        }

        public void ShowWindow()
        {
            window.Show();
            if (window.WindowState == FormWindowState.Minimized) window.WindowState = FormWindowState.Normal;
            window.Activate();
            window.Render(last);
        }

        public void Refresh()
        {
            if (polling) return;
            polling = true;
            Task.Run(() => QueueState.Read()).ContinueWith(t =>
            {
                polling = false;
                last = t.Result;
                onItem.Checked = !last.Off;
                onItem.Enabled = last.Reachable;
                tray.Icon = last.Off || last.Paused ? offIcon : onIcon;
                statusItem.Text = last.Headline;
                var tip = "BlenderRender PC: " + (last.Rendering != null ? $"{(int)(last.Progress * 100)}% " + last.Headline : last.Headline);
                tray.Text = tip.Length > 63 ? tip.Substring(0, 62) + "…" : tip;
                if (window.Visible) window.Render(last);
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        /// Switching off while rendering asks whether to stop now or let the render finish.
        public void SetOn(bool on)
        {
            string args = on ? "on" : "off";
            if (!on && last?.Rendering != null)
            {
                var choice = StopDialog.Ask(window.Visible ? window : null, last);
                if (choice == DialogResult.Cancel) return;
                if (choice == DialogResult.Yes) args = "off --stop";
            }
            Task.Run(() => { try { Rq.Run(args, 30000); return null; } catch (Exception e) { return e.Message; } })
                .ContinueWith(t =>
                {
                    if (t.Result != null) MessageBox.Show(t.Result, "BlenderRender PC", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    Refresh();
                }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        /// The Mac drops a new version in place (rq install-tray); start it and step aside.
        void CheckForUpdate()
        {
            if (!runningInstalled || !File.Exists(Paths.Installed)) return;
            if (File.GetLastWriteTimeUtc(Paths.Installed) == startedFrom) return;
            try { Process.Start(Paths.Installed, "--restarted --tray"); } catch { return; }
            Quit();
        }

        public void Quit()
        {
            timer.Stop();
            tray.Visible = false;
            window.AllowClose = true;
            window.Close();
            ExitThread();
        }
    }

    /// Keeps the queue scripts and the app itself up to date, without a Mac.
    static class SelfUpdate
    {
        const string Latest = "https://api.github.com/repos/AlbertIpsen/blender-render/releases/latest";
        static string Stamp => Path.Combine(Paths.Queue, "pc_release.txt");

        public static void Run()
        {
            try { Scripts(); } catch { }
            try { App(); } catch { }  // offline, or GitHub busy: next time
        }

        /// This copy carries newer queue scripts than the PC has (a Mac may have sent older ones meanwhile).
        static void Scripts()
        {
            if (!Rq.Installed) return;
            int mine = Program.RqVersion(Program.Resource("pc/rq.py"));
            if (mine <= Program.RqVersion(File.ReadAllText(Paths.RqPy))) return;
            Program.ExtractScripts(Paths.Queue);
            Rq.Run("restart-worker", 30000);
        }

        /// A newer BlenderRenderPC.exe in the latest release: put it in place; the running copy restarts from it.
        static void App()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            using (var web = new WebClient())
            {
                web.Headers.Add("User-Agent", "BlenderRenderPC");
                var release = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(web.DownloadString(Latest));
                var tag = Convert.ToString(release["tag_name"]);
                if (File.Exists(Stamp) && File.ReadAllText(Stamp).Trim() == tag) return;
                var asset = ((System.Collections.ArrayList)release["assets"]).Cast<Dictionary<string, object>>()
                    .FirstOrDefault(a => Convert.ToString(a["name"]) == "BlenderRenderPC.exe");
                if (asset != null)
                {
                    var download = Paths.Installed + ".download";
                    web.Headers.Add("User-Agent", "BlenderRenderPC");
                    web.DownloadFile(Convert.ToString(asset["browser_download_url"]), download);
                    var fresh = File.ReadAllBytes(download);
                    var current = File.Exists(Paths.Installed) ? File.ReadAllBytes(Paths.Installed) : new byte[0];
                    // A copy from a Mac's page carries its setup script after the exe itself.
                    bool same = current.Length >= fresh.Length && fresh.SequenceEqual(current.Take(fresh.Length));
                    if (!same)
                    {
                        File.Copy(download, Paths.Installed + ".new", true);
                        Rq.Run("install-tray", 60000);
                    }
                    File.Delete(download);
                }
                File.WriteAllText(Stamp, tag);
            }
        }
    }

    /// Stop now (the render goes back in line) or let it finish first.
    static class StopDialog
    {
        public static DialogResult Ask(IWin32Window owner, QueueState q)
        {
            using (var f = new Form
            {
                Text = "Switch off rendering", FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
                StartPosition = owner == null ? FormStartPosition.CenterScreen : FormStartPosition.CenterParent,
                AutoScaleMode = AutoScaleMode.Dpi, Font = SystemFonts.MessageBoxFont, ShowInTaskbar = owner == null,
                Padding = new Padding(16), AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            })
            {
                var text = new Label
                {
                    AutoSize = true, MaximumSize = new Size(380, 0), Margin = new Padding(0, 0, 0, 14),
                    Text = q.Headline + ".\n\nStop it now? A split job's frames move to another PC; a whole job goes back in line "
                         + "and starts again from the beginning when you switch on.\nOr let it finish, and nothing new starts after it.",
                };
                var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill, Margin = Padding.Empty };
                Button B(string t, DialogResult r) { var b = new Button { Text = t, DialogResult = r, AutoSize = true, MinimumSize = new Size(90, 0) }; buttons.Controls.Add(b); return b; }
                var cancel = B("Cancel", DialogResult.Cancel);
                B("Let It Finish", DialogResult.No);
                var stop = B("Stop Now", DialogResult.Yes);
                var layout = new TableLayoutPanel { AutoSize = true, ColumnCount = 1, Dock = DockStyle.Fill };
                layout.Controls.Add(text);
                layout.Controls.Add(buttons);
                f.Controls.Add(layout);
                f.AcceptButton = stop;
                f.CancelButton = cancel;
                return owner == null ? f.ShowDialog() : f.ShowDialog(owner);
            }
        }
    }

    /// A rounded on/off switch.
    class Switch : Control
    {
        bool on;
        public event EventHandler Toggled;
        public bool On { get => on; set { on = value; Invalidate(); } }

        public Switch()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint
                     | ControlStyles.SupportsTransparentBackColor, true);
            Cursor = Cursors.Hand;
            BackColor = Color.Transparent;
            TabStop = true;
        }

        protected override void OnClick(EventArgs e) { base.OnClick(e); if (Enabled) Toggled?.Invoke(this, e); }
        protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); if (e.KeyCode == Keys.Space && Enabled) Toggled?.Invoke(this, e); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new RectangleF(1, 1, Width - 3, Height - 3);
            float d = r.Height;
            using (var path = new GraphicsPath())
            {
                path.AddArc(r.X, r.Y, d, d, 90, 180);
                path.AddArc(r.Right - d, r.Y, d, d, 270, 180);
                path.CloseFigure();
                var fill = !Enabled ? Color.FromArgb(200, 200, 200) : on ? Color.FromArgb(255, 122, 26) : Color.FromArgb(160, 160, 160);
                using (var b = new SolidBrush(fill)) g.FillPath(b, path);
            }
            float k = d - 6;
            float x = on ? r.Right - k - 3 : r.X + 3;
            using (var b = new SolidBrush(Color.White)) g.FillEllipse(b, x, r.Y + 3, k, k);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(g, ClientRectangle);  // only after Tab
        }
    }

    class MainWindow : Form
    {
        readonly TrayApp app;
        public bool AllowClose;
        readonly Panel statusPanel = new Panel { Dock = DockStyle.Fill };
        readonly Panel setupPanel = new Panel { Dock = DockStyle.Fill };
        readonly Switch toggle = new Switch();
        readonly Label toggleLabel = new Label { AutoSize = true, Text = "Allow this computer to do render jobs" };
        readonly Label headline = new Label { AutoSize = true, MaximumSize = new Size(400, 0) };
        readonly Label detail = new Label { AutoSize = true, MaximumSize = new Size(400, 0), ForeColor = SystemColors.GrayText };
        readonly ProgressBar progress = new ProgressBar { Maximum = 1000, Height = 8, Width = 400 };
        readonly LinkLabel setupAgain = new LinkLabel { AutoSize = true, Text = "Set up again…" };
        readonly Label setupText = new Label { AutoSize = true, MaximumSize = new Size(400, 0) };
        readonly Button setupButton = new Button { Text = "Set Up This PC", AutoSize = true, MinimumSize = new Size(140, 32) };
        readonly ProgressBar setupBusy = new ProgressBar { Style = ProgressBarStyle.Marquee, Width = 400, Height = 8, Visible = false };
        readonly TextBox setupResult = new TextBox { Multiline = true, ReadOnly = true, Width = 400, Height = 110, Visible = false, ScrollBars = ScrollBars.Vertical };
        readonly string script = Program.EmbeddedScript();
        bool settingUp;

        public MainWindow(TrayApp app)
        {
            this.app = app;
            Text = "BlenderRender PC";
            Icon = Program.AppIcon(32);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = SystemFonts.MessageBoxFont;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(460, 300);
            BackColor = SystemColors.Window;

            var header = new Panel { Dock = DockStyle.Top, Height = 64, Padding = new Padding(20, 16, 20, 0) };
            var logo = new PictureBox { Image = Program.AppIcon(48).ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Size = new Size(36, 36), Location = new Point(20, 16) };
            var title = new Label { Text = "BlenderRender PC", AutoSize = true, Location = new Point(64, 14), Font = new Font(Font.FontFamily, 13f, FontStyle.Bold) };
            var sub = new Label { Text = Environment.MachineName, AutoSize = true, Location = new Point(66, 38), ForeColor = SystemColors.GrayText };
            header.Controls.AddRange(new Control[] { logo, title, sub });

            BuildStatus();
            BuildSetup();
            Controls.Add(statusPanel);
            Controls.Add(setupPanel);
            Controls.Add(header);
            ShowPanel();
        }

        void BuildStatus()
        {
            var flow = Column(statusPanel);
            var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 4, 0, 18) };
            toggle.Size = new Size(46, 24);
            toggle.Margin = new Padding(0, 0, 10, 0);
            toggle.Toggled += (s, e) => app.SetOn(!toggle.On);
            toggleLabel.Font = new Font(Font.FontFamily, 10.5f);
            toggleLabel.Margin = new Padding(0, 3, 0, 0);
            toggleLabel.Click += (s, e) => { if (toggle.Enabled) app.SetOn(!toggle.On); };
            row.Controls.Add(toggle);
            row.Controls.Add(toggleLabel);
            headline.Font = new Font(Font.FontFamily, 10f, FontStyle.Bold);
            progress.Margin = new Padding(0, 8, 0, 6);
            var links = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 18, 0, 0) };
            var folder = new LinkLabel { AutoSize = true, Text = "Open render folder", Margin = new Padding(0, 0, 16, 0) };
            folder.LinkClicked += (s, e) => { if (Directory.Exists(Paths.Root)) Process.Start("explorer.exe", Paths.Root); };
            setupAgain.LinkClicked += (s, e) => { setupPanelForced = true; ShowPanel(); };
            links.Controls.Add(folder);
            links.Controls.Add(setupAgain);
            flow.Controls.AddRange(new Control[] { row, headline, progress, detail, links });
        }

        bool setupPanelForced;

        void BuildSetup()
        {
            var flow = Column(setupPanel);
            setupText.Margin = new Padding(0, 4, 0, 16);
            setupButton.Click += (s, e) => RunSetup();
            setupBusy.Margin = new Padding(0, 14, 0, 0);
            setupResult.Margin = new Padding(0, 14, 0, 0);
            flow.Controls.AddRange(new Control[] { setupText, setupButton, setupBusy, setupResult });
        }

        static FlowLayoutPanel Column(Panel host)
        {
            var flow = new FlowLayoutPanel
            {
                Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false,
                Padding = new Padding(20, 8, 20, 16), AutoScroll = true,
            };
            host.Controls.Add(flow);
            return flow;
        }

        bool NeedsSetup => !File.Exists(Paths.RqCmd);

        void ShowPanel()
        {
            bool setup = settingUp || setupPanelForced || NeedsSetup;
            setupPanel.Visible = setup;
            statusPanel.Visible = !setup;
            setupAgain.Visible = script != null;
            if (!setup) return;
            if (settingUp) return;
            setupButton.Visible = true;
            setupText.Text = Program.FromMac
                ? "Sets this PC up to render for your Mac: turns on Windows' SSH server so the Mac can send it "
                  + "files, lets in the Mac's key, makes the render folder C:\\GeysierRender, and pairs with the Mac.\n\n"
                  + "Windows asks once for permission. It can take a few minutes the first time."
                : "Sets this PC up to render for Macs with BlenderRender on this network: makes the render folder "
                  + "C:\\GeysierRender, starts the render queue with Windows, and lets the Macs reach it on private networks.\n\n"
                  + "Install Blender first. Windows asks once for permission.";
        }

        public void Render(QueueState q)
        {
            ShowPanel();
            if (q == null) return;
            toggle.On = !q.Off;
            toggle.Enabled = q.Reachable;
            toggleLabel.Enabled = q.Reachable;
            headline.Text = q.Headline;
            detail.Text = q.Detail;
            progress.Visible = q.Rendering != null;
            progress.Value = Math.Max(0, Math.Min(1000, (int)(q.Progress * 1000)));
        }

        /// Runs the Mac's setup script elevated, then starts the installed copy in the taskbar corner.
        void RunSetup()
        {
            var dir = Path.Combine(Path.GetTempPath(), "BlenderRenderPC-setup");
            Directory.CreateDirectory(dir);
            var log = Path.Combine(dir, "log.txt");
            File.Delete(log);
            var scripts = Path.Combine(dir, "scripts");
            Program.ExtractScripts(scripts);
            File.WriteAllText(Path.Combine(dir, "setup.ps1"),
                "$TrayExe = '" + Application.ExecutablePath.Replace("'", "''") + "'\r\n"
                + "$ScriptsDir = '" + scripts.Replace("'", "''") + "'\r\n" + script, new UTF8Encoding(true));
            File.WriteAllText(Path.Combine(dir, "run.ps1"),
                "try { & \"$PSScriptRoot\\setup.ps1\" *>&1 | ForEach-Object { \"$_\" } | Out-File -Encoding utf8 \"$PSScriptRoot\\log.txt\"; exit 0 }\r\n" +
                "catch { \"ERROR: $($_.Exception.Message)\" | Out-File -Append -Encoding utf8 \"$PSScriptRoot\\log.txt\"; exit 1 }\r\n",
                new UTF8Encoding(true));
            var psi = new ProcessStartInfo("powershell.exe",
                $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{Path.Combine(dir, "run.ps1")}\"")
            { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
            Process p;
            try { p = Process.Start(psi); }
            catch (System.ComponentModel.Win32Exception) { return; }  // said no to Windows' prompt

            settingUp = true;
            setupButton.Enabled = false;
            setupBusy.Visible = true;
            setupResult.Visible = false;
            setupText.Text = "Setting up… Windows may take a few minutes to add its SSH server.";
            Task.Run(() => { p.WaitForExit(); return p.ExitCode; }).ContinueWith(t =>
            {
                settingUp = false;
                setupPanelForced = false;
                setupBusy.Visible = false;
                setupButton.Enabled = true;
                var lines = File.Exists(log) ? File.ReadAllLines(log) : new string[0];
                bool ok = t.Result == 0 && File.Exists(Paths.RqCmd);
                var code = lines.FirstOrDefault(l => l.StartsWith("BR1:"));
                bool sent = code == null || lines.Any(l => l.Contains("Sent to the Mac"));
                var notes = lines.Where(l => l.StartsWith("!!")).Select(l => l.Substring(2).Trim()).ToList();
                if (ok)
                {
                    setupText.Text = !Program.FromMac
                        ? "Done. Macs with BlenderRender on this network now see this PC: on a Mac, open Settings and "
                          + "click Add next to it under On This Network. BlenderRender PC starts with Windows in the taskbar corner."
                        : sent
                        ? "Done. This PC is paired with your Mac, and BlenderRender PC now starts with Windows in the taskbar corner."
                        : "Done, but the pairing code couldn't reach the Mac. In Add PC on the Mac, paste the code below.";
                    setupResult.Text = string.Join("\r\n", (sent ? new string[0] : new[] { code, "" }).Concat(notes));
                    setupResult.Visible = !sent || notes.Count > 0;
                    StartInstalledCopy();
                }
                else if (lines.Any(l => l.Contains("NOT FOUND")))
                {
                    setupText.Text = "Blender isn't installed. Install it from blender.org in its default folder "
                                   + "(the same version as your Macs), then click Set Up This PC again.";
                }
                else
                {
                    setupText.Text = "Setup didn't finish. What it said:";
                    setupResult.Text = string.Join("\r\n", lines.Reverse().Take(12).Reverse());
                    setupResult.Visible = true;
                }
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        /// Hand over to the copy setup put in the queue folder, unless this is it.
        void StartInstalledCopy()
        {
            bool isInstalled = string.Equals(Path.GetFullPath(Application.ExecutablePath), Paths.Installed, StringComparison.OrdinalIgnoreCase);
            if (isInstalled || !File.Exists(Paths.Installed)) { app.Refresh(); return; }
            var done = new Button { Text = "Close", AutoSize = true, MinimumSize = new Size(100, 30), Margin = new Padding(0, 14, 0, 0) };
            setupButton.Visible = false;
            done.Click += (s, e) =>
            {
                try { Process.Start(Paths.Installed, "--restarted"); } catch { }
                app.Quit();
            };
            setupPanel.Controls[0].Controls.Add(done);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!AllowClose && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;  // closing the window leaves the app in the taskbar corner
                Hide();
            }
            base.OnFormClosing(e);
        }
    }
}
