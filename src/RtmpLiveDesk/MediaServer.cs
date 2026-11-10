using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RtmpLiveDesk;

internal sealed class MediaServer : IDisposable
{
    private readonly HttpClient http = new(new SocketsHttpHandler { UseProxy = false })
    {
        Timeout = TimeSpan.FromSeconds(1)
    };
    private readonly object logLock = new();
    private readonly Queue<string> log = new();
    private Process? process;
    private WindowsJob? job;
    private string? runtimeDirectory;
    private int apiPort;
    private string apiPassword = "";

    internal bool Running => process is { HasExited: false };

    internal string LogText
    {
        get
        {
            lock (logLock)
                return string.Join(Environment.NewLine, log);
        }
    }

    internal async Task StartAsync(AppSettings settings)
    {
        settings.Validate();
        await StopAsync();
        apiPort = PickApiPort();
        apiPassword = Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
        runtimeDirectory = Path.Combine(AppSettings.DataDirectory, "runtime-" + Guid.NewGuid().ToString("N"));
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var rtmpListening = false;
        var apiListening = false;
        var lastError = "";

        try
        {
            Directory.CreateDirectory(runtimeDirectory);
            var configPath = Path.Combine(runtimeDirectory, "mediamtx.yml");
            File.WriteAllText(configPath, BuildConfig(settings));
            var startInfo = new ProcessStartInfo
            {
                FileName = Path.Combine(AppContext.BaseDirectory, "server", "mediamtx.exe"),
                WorkingDirectory = runtimeDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            startInfo.ArgumentList.Add(configPath);
            foreach (var name in startInfo.Environment.Keys.Where(name => name.StartsWith("MTX_", StringComparison.OrdinalIgnoreCase)).ToArray())
                startInfo.Environment.Remove(name);

            var child = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            child.OutputDataReceived += (_, args) => OnLine(args.Data);
            child.ErrorDataReceived += (_, args) => OnLine(args.Data);
            child.Exited += (_, _) =>
            {
                lock (logLock)
                    ready.TrySetException(new InvalidOperationException(
                        lastError.Length > 0 ? lastError : "RTMP 服务退出。请查看服务日志。"));
            };
            job = new WindowsJob();
            if (!child.Start())
                throw new InvalidOperationException("无法启动 RTMP 服务。");
            process = child;
            job.Attach(child);
            child.BeginOutputReadLine();
            child.BeginErrorReadLine();
            await ready.Task.WaitAsync(TimeSpan.FromSeconds(8));
            if (child.HasExited)
                throw new InvalidOperationException("RTMP 服务启动后退出。请查看服务日志。");
        }
        catch
        {
            await StopAsync();
            throw;
        }

        void OnLine(string? line)
        {
            if (line is null) return;
            lock (logLock)
            {
                log.Enqueue(line);
                if (log.Count > 80) log.Dequeue();
                if (line.Contains(" ERR ", StringComparison.Ordinal)) lastError = line;
                rtmpListening |= line.Contains("[RTMP] started with listener on", StringComparison.Ordinal);
                apiListening |= line.Contains("[API] started with listener on", StringComparison.Ordinal);
                if (rtmpListening && apiListening) ready.TrySetResult();
            }
        }
    }

    internal async Task StopAsync()
    {
        var child = process;
        process = null;
        job?.Dispose();
        job = null;
        if (child is not null)
        {
            using (child)
            {
                if (!child.HasExited)
                {
                    try { child.Kill(entireProcessTree: true); }
                    catch (InvalidOperationException) when (child.HasExited) { }
                    await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(4));
                }
            }
        }
        CleanRuntime();
    }

    internal async Task<bool> PublisherOnlineAsync(string path)
    {
        if (!Running) return false;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"http://127.0.0.1:{apiPort}/v3/paths/list");
            request.Headers.Authorization = new AuthenticationHeaderValue("Basic",
                Convert.ToBase64String(Encoding.ASCII.GetBytes("local-panel:" + apiPassword)));
            using var response = await http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return false;
            using var stream = await response.Content.ReadAsStreamAsync();
            using var document = await JsonDocument.ParseAsync(stream);
            if (!document.RootElement.TryGetProperty("items", out var items) || items.ValueKind != JsonValueKind.Array)
                return false;
            return items.EnumerateArray().Any(item => item.GetProperty("name").GetString() == path &&
                item.TryGetProperty("online", out var online) && online.ValueKind == JsonValueKind.True);
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or JsonException)
        {
            return false;
        }
    }

    public void Dispose()
    {
        job?.Dispose();
        process?.Dispose();
        http.Dispose();
        CleanRuntime();
    }

    private void CleanRuntime()
    {
        if (runtimeDirectory is not { } directory) return;
        runtimeDirectory = null;
        try
        {
            File.Delete(Path.Combine(directory, "mediamtx.yml"));
            if (Directory.Exists(directory)) Directory.Delete(directory);
        }
        catch (IOException) { }
    }

    private static int PickApiPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private string BuildConfig(AppSettings settings) => $$"""
        logLevel: info
        logDestinations: [stdout]
        authMethod: internal
        authInternalUsers:
          - user: any
            permissions:
              - action: publish
                path: {{settings.StreamPath}}
              - action: read
                path: {{settings.StreamPath}}
          - user: local-panel
            pass: "{{apiPassword}}"
            ips: [127.0.0.1]
            permissions:
              - action: api
        api: true
        apiAddress: 127.0.0.1:{{apiPort}}
        rtmp: true
        rtmpAddress: "{{settings.BindEndpoint}}"
        rtsp: false
        hls: false
        webrtc: false
        srt: false
        moq: false
        paths:
          {{settings.StreamPath}}:
            source: publisher
            overridePublisher: false
        """;
}
