using LibVLCSharp.Shared;

namespace RtmpLiveDesk;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var instance = new Mutex(true, @"Local\RtmpLiveDesk", out var firstInstance);
        ApplicationConfiguration.Initialize();
        if (!firstInstance)
        {
            MessageBox.Show("RTMP Live Desk 已运行。", "RTMP Live Desk");
            return;
        }

        try
        {
            Core.Initialize(Path.Combine(AppContext.BaseDirectory, "vlc"));
            using var window = new MainWindow();
            Application.Run(window);
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "RTMP Live Desk 启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
