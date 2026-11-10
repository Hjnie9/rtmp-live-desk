using LibVLCSharp.Shared;
using LibVLCSharp.WinForms;

namespace RtmpLiveDesk;

internal sealed class MainWindow : Form
{
    private static readonly Color Ink = Color.FromArgb(236, 243, 252);
    private static readonly Color Muted = Color.FromArgb(157, 176, 198);
    private static readonly Color Accent = Color.FromArgb(86, 231, 177);
    private static readonly Color Canvas = Color.FromArgb(15, 21, 32);
    private static readonly Color Surface = Color.FromArgb(24, 34, 50);
    private static readonly Color Field = Color.FromArgb(15, 24, 37);
    private static readonly Color Line = Color.FromArgb(46, 62, 82);
    private static readonly Color VideoColor = Color.FromArgb(8, 13, 22);

    private readonly MediaServer server = new();
    private readonly LibVLC vlc = LivePreview.CreateEngine();
    private readonly MediaPlayer player;
    private readonly VideoView view = new() { Dock = DockStyle.Fill, BackColor = VideoColor, TabStop = false };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 400 };
    private readonly ComboBox addresses = new()
    {
        DropDownStyle = ComboBoxStyle.DropDownList, DrawMode = DrawMode.OwnerDrawFixed,
        Dock = DockStyle.Top, BackColor = Field, ForeColor = Ink, FlatStyle = FlatStyle.Flat
    };
    private readonly NumericUpDown port = new()
    {
        Minimum = 1, Maximum = 65535, Dock = DockStyle.Top, BackColor = Field, ForeColor = Ink,
        BorderStyle = BorderStyle.FixedSingle
    };
    private readonly TextBox key = TextField();
    private readonly TextBox publish = TextField(readOnly: true);
    private readonly TextBox activeKey = TextField(readOnly: true);
    private readonly RichTextBox logs = new()
    {
        Dock = DockStyle.Fill, ReadOnly = true, Multiline = true, WordWrap = false,
        DetectUrls = false, ScrollBars = RichTextBoxScrollBars.Vertical, BackColor = Field, ForeColor = Muted,
        BorderStyle = BorderStyle.None,
        Font = new Font("Consolas", 9F), Margin = new Padding(0)
    };
    private readonly Label state = new()
    {
        AutoSize = true, Anchor = AnchorStyles.Right, ForeColor = Muted, BackColor = Surface,
        Padding = new Padding(12, 8, 12, 8), Text = "●  服务已停止"
    };
    private readonly Label notice = new()
    {
        AutoSize = true, ForeColor = Muted, MaximumSize = new Size(316, 0), Margin = new Padding(1, 12, 0, 0),
        Text = "启动服务后，按面板显示的地址推流。"
    };
    private readonly Label placeholder = new()
    {
        Dock = DockStyle.Fill, BackColor = VideoColor, ForeColor = Color.FromArgb(207, 223, 237),
        TextAlign = ContentAlignment.MiddleCenter, Text = "等待启动服务", Font = new Font("Microsoft YaHei UI", 13F)
    };
    private readonly Button start = Button("启动", true);
    private readonly Button stop = Button("停止");
    private readonly Button restart = Button("重启");
    private readonly Button save = Button("保存并应用");
    private readonly Button mute = Button("打开声音");
    private readonly Button liveEdge = Button("回到直播");
    private readonly Icon applicationIcon = LoadIcon();
    private Bitmap? brandImage;
    private AppSettings settings = AppSettings.Load();
    private bool busy, polling, publishing, previewRequested, muted = true, closing, exitReady;
    private int revision;
    private DateTime nextPreviewAttempt;

    internal MainWindow()
    {
        Text = "RTMP Live Desk";
        AutoScaleMode = AutoScaleMode.Dpi;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(1160, 700);
        MinimumSize = new Size(950, 650);
        BackColor = Canvas;
        ForeColor = Ink;
        Icon = applicationIcon;
        key.MaxLength = 64;

        player = new MediaPlayer(vlc) { EnableMouseInput = false, EnableKeyInput = false };
        view.MediaPlayer = player;
        Controls.Add(BuildLayout());
        LoadInputs();
        RefreshControls();

        addresses.DropDown += (_, _) => LoadAddresses((addresses.SelectedItem as InterfaceAddress)?.Address ?? "");
        addresses.DrawItem += DrawAddress;
        start.Click += async (_, _) => await RunAsync(() => ApplyAsync(startWhenStopped: true));
        restart.Click += async (_, _) => await RunAsync(() => ApplyAsync(forceRestart: true));
        stop.Click += async (_, _) => await RunAsync(async () =>
        {
            await StopMediaAsync();
            notice.Text = "RTMP 服务已停止。";
        });
        save.Click += async (_, _) => await RunAsync(() => ApplyAsync());
        mute.Click += (_, _) =>
        {
            muted = !muted;
            player.Mute = muted;
            mute.Text = muted ? "打开声音" : "静音";
        };
        liveEdge.Click += async (_, _) =>
        {
            if (busy || !publishing) return;
            StopPreview();
            nextPreviewAttempt = DateTime.MinValue;
            await PollAsync();
        };
        timer.Tick += async (_, _) => await PollAsync();
        Shown += (_, _) => timer.Start();
        FormClosing += CloseWindow;
    }

    private Control BuildLayout()
    {
        var frame = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, Padding = new Padding(22, 13, 22, 18),
            ColumnCount = 2, RowCount = 2
        };
        frame.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        frame.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 352));
        frame.RowStyles.Add(new RowStyle(SizeType.Absolute, 76));
        frame.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Margin = new Padding(0, 0, 0, 13)
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 57));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        brandImage = applicationIcon.ToBitmap();
        header.Controls.Add(new PictureBox
        {
            Image = brandImage, Size = new Size(45, 45), SizeMode = PictureBoxSizeMode.Zoom, Anchor = AnchorStyles.Left
        }, 0, 0);
        var heading = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Margin = new Padding(0) };
        heading.RowStyles.Add(new RowStyle(SizeType.Percent, 64));
        heading.RowStyles.Add(new RowStyle(SizeType.Percent, 36));
        var title = Label("RTMP Live Desk", 19, FontStyle.Bold, Ink);
        title.AutoSize = false;
        title.Dock = DockStyle.Fill;
        title.Margin = new Padding(0);
        title.TextAlign = ContentAlignment.MiddleLeft;
        var caption = Label("桌面直播控制台", 9F, FontStyle.Regular, Muted);
        caption.AutoSize = false;
        caption.Dock = DockStyle.Fill;
        caption.Margin = new Padding(0);
        caption.TextAlign = ContentAlignment.TopLeft;
        heading.Controls.Add(title, 0, 0);
        heading.Controls.Add(caption, 0, 1);
        header.Controls.Add(heading, 1, 0);
        header.Controls.Add(state, 2, 0);
        frame.Controls.Add(header, 0, 0);
        frame.SetColumnSpan(header, 2);

        var sideCard = new DeskCard(Surface, Line)
        {
            Dock = DockStyle.Fill, Padding = new Padding(16), Margin = new Padding(0)
        };
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, BackColor = Surface, ColumnCount = 1, AutoScroll = true, Margin = new Padding(0)
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.Controls.Add(Label("推流设置", 14, FontStyle.Bold, Ink));
        AddField(panel, "监听地址", addresses);
        var options = new TableLayoutPanel
        {
            ColumnCount = 2, RowCount = 2, Dock = DockStyle.Top, AutoSize = true, Margin = new Padding(0, 5, 0, 4)
        };
        options.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 99));
        options.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        options.Controls.Add(Label("RTMP 端口", 9.5F, FontStyle.Regular, Muted), 0, 0);
        options.Controls.Add(Label("串流密钥", 9.5F, FontStyle.Regular, Muted), 1, 0);
        port.Margin = new Padding(0, 0, 10, 0);
        key.Margin = new Padding(0);
        options.Controls.Add(port, 0, 1);
        options.Controls.Add(key, 1, 1);
        panel.Controls.Add(options);
        panel.Controls.Add(Row(start, stop, restart));
        panel.Controls.Add(Row(save));
        panel.Controls.Add(Label("OBS 推流参数", 14, FontStyle.Bold, Ink));
        AddField(panel, "服务器", publish);
        AddField(panel, "串流密钥（留空时无需填写）", activeKey);
        var copyAddress = Button("复制地址");
        copyAddress.Click += (_, _) => Copy(publish.Text, "已复制推流地址。");
        var copyKey = Button("复制密钥");
        copyKey.Click += (_, _) => Copy(activeKey.Text, "已复制串流密钥。");
        panel.Controls.Add(Row(copyAddress, copyKey));
        panel.Controls.Add(notice);
        sideCard.Controls.Add(panel);
        frame.Controls.Add(sideCard, 1, 1);

        var previewCard = new DeskCard(Surface, Line)
        {
            Dock = DockStyle.Fill, Padding = new Padding(15), Margin = new Padding(0, 0, 14, 0)
        };
        var monitor = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, BackColor = Surface, ColumnCount = 1, RowCount = 5, Margin = new Padding(0)
        };
        monitor.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        monitor.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        monitor.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        monitor.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        monitor.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        monitor.RowStyles.Add(new RowStyle(SizeType.Absolute, 101));
        monitor.Controls.Add(Label("直播预览", 14, FontStyle.Bold, Ink), 0, 0);
        var surface = new Panel { Dock = DockStyle.Fill, Margin = new Padding(0), BackColor = VideoColor };
        surface.Controls.Add(view);
        surface.Controls.Add(placeholder);
        placeholder.BringToFront();
        monitor.Controls.Add(surface, 0, 1);
        monitor.Controls.Add(Row(liveEdge, mute), 0, 2);
        monitor.Controls.Add(Label("服务日志", 9.5F, FontStyle.Bold, Muted), 0, 3);
        monitor.Controls.Add(logs, 0, 4);
        previewCard.Controls.Add(monitor);
        frame.Controls.Add(previewCard, 0, 1);
        return frame;
    }

    private static void AddField(TableLayoutPanel panel, string text, Control field)
    {
        var label = Label(text, 9.5F, FontStyle.Regular, Muted);
        label.Margin = new Padding(1, 7, 1, 3);
        field.Margin = new Padding(0, 0, 0, 4);
        panel.Controls.Add(label);
        panel.Controls.Add(field);
    }

    private static Label Label(string text, float size, FontStyle style, Color color) => new()
    {
        Text = text, Font = new Font("Microsoft YaHei UI", size, style),
        ForeColor = color, AutoSize = true, Margin = new Padding(3, 4, 3, 4)
    };

    private static Button Button(string text, bool primary = false) =>
        new DeskButton(text, primary ? Accent : Field, primary ? VideoColor : Ink, primary ? Accent : Line, Muted);

    private static TextBox TextField(bool readOnly = false) => new()
    {
        ReadOnly = readOnly, Dock = DockStyle.Top, BackColor = Field, ForeColor = Ink, BorderStyle = BorderStyle.FixedSingle
    };

    private static Icon LoadIcon()
    {
        using var stream = typeof(MainWindow).Assembly.GetManifestResourceStream("RtmpLiveDesk.App.ico")
            ?? throw new InvalidOperationException("应用图标资源缺失。");
        return new Icon(stream, 48, 48);
    }

    private void DrawAddress(object? sender, DrawItemEventArgs e)
    {
        if (e.Index < 0) return;
        var selected = e.State.HasFlag(DrawItemState.Selected);
        using var background = new SolidBrush(selected ? Line : Field);
        e.Graphics.FillRectangle(background, e.Bounds);
        var text = addresses.Items[e.Index]?.ToString() ?? "";
        TextRenderer.DrawText(e.Graphics, text, addresses.Font, Rectangle.Inflate(e.Bounds, -5, 0), Ink,
            TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        e.DrawFocusRectangle();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        DeskChrome.ApplyCaption(Handle, Canvas, Ink);
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing)
        {
            brandImage?.Dispose();
            applicationIcon.Dispose();
        }
    }

    private static FlowLayoutPanel Row(params Button[] buttons)
    {
        var row = new FlowLayoutPanel
        {
            AutoSize = true, Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0, 4, 0, 3)
        };
        row.Controls.AddRange(buttons);
        return row;
    }

    private void LoadInputs()
    {
        LoadAddresses(settings.ListenAddress);
        port.Value = settings.Port;
        key.Text = settings.StreamKey;
        publish.Text = settings.PushServer;
        activeKey.Text = settings.StreamKey;
    }

    private void LoadAddresses(string selected)
    {
        var options = AppSettings.Addresses().ToList();
        if (!options.Any(option => option.Address == selected))
            options.Add(new(selected, selected + "（当前不可用）"));
        addresses.BeginUpdate();
        addresses.Items.Clear();
        addresses.Items.AddRange(options.Cast<object>().ToArray());
        addresses.SelectedIndex = options.FindIndex(option => option.Address == selected);
        addresses.EndUpdate();
    }

    private async Task RunAsync(Func<Task> operation)
    {
        if (busy || closing) return;
        busy = true;
        revision++;
        notice.ForeColor = Muted;
        notice.Text = "正在应用操作…";
        RefreshControls();
        try { await operation(); }
        catch (Exception error)
        {
            notice.ForeColor = Color.FromArgb(255, 153, 158);
            notice.Text = error.Message;
        }
        finally
        {
            busy = false;
            RefreshControls();
        }
    }

    private async Task ApplyAsync(bool startWhenStopped = false, bool forceRestart = false)
    {
        var next = new AppSettings((addresses.SelectedItem as InterfaceAddress)?.Address ?? "", (int)port.Value, key.Text.Trim());
        next.Validate();
        var wasRunning = server.Running;
        if (wasRunning && !forceRestart && next == settings)
        {
            notice.Text = "已使用当前设置。";
            return;
        }
        if (wasRunning) await StopMediaAsync();
        try
        {
            if (wasRunning || startWhenStopped) await server.StartAsync(next);
            next.Save();
            settings = next;
            LoadInputs();
            notice.Text = server.Running ? "RTMP 服务已启动，等待推流。" : "设置已保存。";
        }
        catch
        {
            if (server.Running) await StopMediaAsync();
            if (wasRunning)
            {
                try { await server.StartAsync(settings); }
                catch (Exception recovery) { throw new InvalidOperationException("恢复服务时出错。 " + recovery.Message, recovery); }
            }
            throw;
        }
    }

    private async Task PollAsync()
    {
        if (polling || busy || closing) return;
        polling = true;
        var stamp = revision;
        try
        {
            var online = await server.PublisherOnlineAsync(settings.StreamPath);
            if (stamp != revision || busy || closing) return;
            publishing = online;
            if (!publishing)
                StopPreview();
            else if (!player.IsPlaying && DateTime.UtcNow >= nextPreviewAttempt)
            {
                StopPreview();
                nextPreviewAttempt = DateTime.UtcNow.AddSeconds(5);
                view.Show();
                placeholder.Hide();
                _ = view.Handle;
                using var media = new Media(vlc, server.PreviewUrl(settings.StreamPath), FromType.FromLocation);
                previewRequested = player.Play(media);
                player.Mute = muted;
            }
            RefreshControls();
        }
        catch (Exception error)
        {
            notice.Text = "预览暂时不可用。 " + error.Message;
        }
        finally { polling = false; }
    }

    private async Task StopMediaAsync()
    {
        await server.StopAsync();
        publishing = false;
        StopPreview();
        nextPreviewAttempt = DateTime.MinValue;
    }

    private void StopPreview()
    {
        if (previewRequested)
            player.Stop();
        previewRequested = false;
    }

    private void RefreshControls()
    {
        var running = server.Running;
        start.Enabled = !busy && !running;
        stop.Enabled = restart.Enabled = !busy && running;
        addresses.Enabled = port.Enabled = key.Enabled = save.Enabled = !busy;
        liveEdge.Enabled = !busy && publishing;
        state.Text = busy ? "●  正在应用设置"
            : !running ? "●  服务已停止"
            : !publishing ? "●  等待推流"
            : player.IsPlaying ? "●  直播中" : "●  正在连接预览";
        state.ForeColor = running ? Accent : Muted;
        placeholder.Text = running ? publishing ? "正在接入实时画面…" : "等待 RTMP 推流" : "等待启动服务";
        view.Visible = previewRequested;
        placeholder.Visible = !previewRequested;
        var latest = server.LogText;
        if (logs.Text != latest)
        {
            logs.Text = latest;
            logs.SelectionStart = logs.TextLength;
            logs.ScrollToCaret();
        }
    }

    private void Copy(string text, string confirmation)
    {
        if (text.Length == 0)
        {
            notice.Text = "当前串流密钥留空。";
            return;
        }
        try
        {
            Clipboard.SetText(text);
            notice.Text = confirmation;
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            notice.Text = "剪贴板暂不可用，可选中文字手动复制。";
        }
    }

    private async void CloseWindow(object? sender, FormClosingEventArgs args)
    {
        if (exitReady) return;
        args.Cancel = true;
        if (busy || closing) return;
        closing = true;
        timer.Stop();
        try { await StopMediaAsync(); }
        catch (Exception) { }
        server.Dispose();
        view.MediaPlayer = null;
        player.Dispose();
        vlc.Dispose();
        timer.Dispose();
        exitReady = true;
        Close();
    }
}
