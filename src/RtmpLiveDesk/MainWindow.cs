using LibVLCSharp.Shared;
using LibVLCSharp.WinForms;

namespace RtmpLiveDesk;

internal sealed class MainWindow : Form
{
    private static readonly Color Ink = Color.FromArgb(26, 40, 58);
    private static readonly Color Muted = Color.FromArgb(78, 96, 114);
    private static readonly Color Accent = Color.FromArgb(10, 104, 89);
    private static readonly Color Canvas = Color.FromArgb(240, 244, 247);
    private static readonly Color VideoColor = Color.FromArgb(16, 24, 35);

    private readonly MediaServer server = new();
    private readonly LibVLC vlc = new("--no-video-title-show", "--network-caching=150", "--live-caching=150");
    private readonly MediaPlayer player;
    private readonly VideoView view = new() { Dock = DockStyle.Fill, BackColor = VideoColor, TabStop = false };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 750 };
    private readonly ComboBox addresses = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Top };
    private readonly NumericUpDown port = new() { Minimum = 1, Maximum = 65535, Dock = DockStyle.Top };
    private readonly TextBox key = new() { MaxLength = 64, Dock = DockStyle.Top };
    private readonly TextBox publish = new() { ReadOnly = true, Dock = DockStyle.Top };
    private readonly TextBox activeKey = new() { ReadOnly = true, Dock = DockStyle.Top };
    private readonly TextBox logs = new()
    {
        Dock = DockStyle.Fill, ReadOnly = true, Multiline = true, WordWrap = false,
        ScrollBars = ScrollBars.Vertical, BackColor = Color.White, BorderStyle = BorderStyle.FixedSingle,
        Font = new Font("Consolas", 9F)
    };
    private readonly Label state = new() { AutoSize = true, ForeColor = Muted, Text = "服务已停止" };
    private readonly Label notice = new() { Dock = DockStyle.Fill, ForeColor = Muted, Text = "启动服务后，按面板显示的地址推流。" };
    private readonly Label placeholder = new()
    {
        Dock = DockStyle.Fill, BackColor = VideoColor, ForeColor = Color.FromArgb(207, 223, 237),
        TextAlign = ContentAlignment.MiddleCenter, Text = "等待启动服务"
    };
    private readonly Button start = Button("启动", true);
    private readonly Button stop = Button("停止");
    private readonly Button restart = Button("重启");
    private readonly Button save = Button("保存并应用");
    private readonly Button mute = Button("打开声音");
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
        MinimumSize = new Size(970, 650);
        BackColor = Canvas;
        ForeColor = Ink;

        player = new MediaPlayer(vlc) { EnableMouseInput = false, EnableKeyInput = false };
        view.MediaPlayer = player;
        Controls.Add(BuildLayout());
        LoadInputs();
        RefreshControls();

        addresses.DropDown += (_, _) => LoadAddresses((addresses.SelectedItem as InterfaceAddress)?.Address ?? "");
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
        timer.Tick += async (_, _) => await PollAsync();
        Shown += (_, _) => timer.Start();
        FormClosing += CloseWindow;
    }

    private Control BuildLayout()
    {
        var frame = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, Padding = new Padding(20, 16, 20, 18),
            ColumnCount = 2, RowCount = 2
        };
        frame.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 356));
        frame.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        frame.RowStyles.Add(new RowStyle(SizeType.Absolute, 68));
        frame.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var heading = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false };
        heading.Controls.Add(Label("RTMP Live Desk", 22, FontStyle.Bold, Ink));
        heading.Controls.Add(state);
        frame.Controls.Add(heading, 0, 0);
        frame.SetColumnSpan(heading, 2);

        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, Margin = new Padding(0, 0, 14, 0),
            Padding = new Padding(17), BackColor = Color.White, ColumnCount = 1, AutoScroll = true
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.Controls.Add(Label("推流设置", 14, FontStyle.Bold, Ink));
        AddField(panel, "监听地址", addresses);
        AddField(panel, "RTMP 端口", port);
        AddField(panel, "串流密钥", key);
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
        frame.Controls.Add(panel, 0, 1);

        var monitor = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Margin = new Padding(0) };
        monitor.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        monitor.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        monitor.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        monitor.RowStyles.Add(new RowStyle(SizeType.Absolute, 43));
        monitor.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        monitor.RowStyles.Add(new RowStyle(SizeType.Absolute, 106));
        monitor.Controls.Add(Label("实时预览", 14, FontStyle.Bold, Ink), 0, 0);
        var surface = new Panel { Dock = DockStyle.Fill, Margin = new Padding(0), BackColor = VideoColor };
        surface.Controls.Add(view);
        surface.Controls.Add(placeholder);
        placeholder.BringToFront();
        monitor.Controls.Add(surface, 0, 1);
        monitor.Controls.Add(Row(mute), 0, 2);
        monitor.Controls.Add(Label("服务日志", 10, FontStyle.Bold, Ink), 0, 3);
        monitor.Controls.Add(logs, 0, 4);
        frame.Controls.Add(monitor, 1, 1);
        return frame;
    }

    private static void AddField(TableLayoutPanel panel, string text, Control field)
    {
        var label = Label(text, 9.5F, FontStyle.Regular, Muted);
        label.Margin = new Padding(3, 9, 3, 2);
        panel.Controls.Add(label);
        panel.Controls.Add(field);
    }

    private static Label Label(string text, float size, FontStyle style, Color color) => new()
    {
        Text = text, Font = new Font("Microsoft YaHei UI", size, style),
        ForeColor = color, AutoSize = true, Margin = new Padding(3, 4, 3, 4)
    };

    private static Button Button(string text, bool primary = false)
    {
        var button = new Button
        {
            Text = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(9, 3, 9, 3),
            MinimumSize = new Size(58, 30), FlatStyle = FlatStyle.Flat,
            BackColor = primary ? Accent : Color.White, ForeColor = primary ? Color.White : Ink
        };
        button.FlatAppearance.BorderColor = primary ? Accent : Color.FromArgb(198, 211, 223);
        return button;
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
            notice.ForeColor = Color.FromArgb(155, 39, 42);
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
                using var media = new Media(vlc, settings.PreviewUrl, FromType.FromLocation);
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
        state.Text = busy ? "正在应用设置" : running ? publishing ? "● 直播中" : "● 服务运行中 · 等待推流" : "服务已停止";
        state.ForeColor = running ? Accent : Muted;
        placeholder.Text = running ? publishing ? "正在接入实时画面…" : "等待 RTMP 推流" : "等待启动服务";
        placeholder.Visible = !player.IsPlaying;
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
