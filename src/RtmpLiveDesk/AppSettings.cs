using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RtmpLiveDesk;

internal sealed record AppSettings(string ListenAddress = "", int Port = 1935, string StreamKey = "")
{
    internal static readonly string DataDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RtmpLiveDesk");
    private static readonly string SettingsFile = Path.Combine(DataDirectory, "settings.json");
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    internal string StreamPath => StreamKey.Length == 0 ? "live" : "live/" + StreamKey;
    internal string BindEndpoint => Authority(ListenAddress, Port, false);
    internal string PushServer => "rtmp://" + Authority(
        ListenAddress.Length == 0 ? PreferredAddress() : ListenAddress, Port, true) + "/live";
    internal string PreviewUrl => "rtmp://" + Authority(
        ListenAddress.Length == 0 ? "127.0.0.1" : ListenAddress, Port, true) + "/" + StreamPath;

    internal void Validate()
    {
        if (Port is < 1 or > 65535)
            throw new ArgumentException("RTMP 端口应为 1 到 65535。");
        if (!Regex.IsMatch(StreamKey, @"\A[A-Za-z0-9_-]{0,64}\z"))
            throw new ArgumentException("串流密钥最多 64 位，可使用字母、数字、下划线和连字符。");
        if (ListenAddress.Length != 0 && !Addresses().Any(option => option.Address == ListenAddress))
            throw new ArgumentException("请选择当前可用的监听地址。");
    }

    internal static AppSettings Load()
    {
        try
        {
            var result = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsFile));
            return result is { ListenAddress: not null, StreamKey: not null } &&
                result.Port is >= 1 and <= 65535 ? result : new();
        }
        catch (Exception error) when (error is IOException or JsonException)
        {
            return new();
        }
    }

    internal void Save()
    {
        Directory.CreateDirectory(DataDirectory);
        var temporary = SettingsFile + ".new";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(this, JsonOptions));
            File.Move(temporary, SettingsFile, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    internal static IReadOnlyList<InterfaceAddress> Addresses()
    {
        var result = new List<InterfaceAddress> { new("", "所有地址（IPv4 / IPv6）") };
        var seen = new HashSet<string>();
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces()
                     .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up))
        {
            foreach (var item in adapter.GetIPProperties().UnicastAddresses)
            {
                var address = item.Address.ToString();
                if (seen.Add(address))
                    result.Add(new(address, (IPAddress.IsLoopback(item.Address) ? "本机回环" : adapter.Name) + " · " + address));
            }
        }
        return result;
    }

    private static string PreferredAddress()
    {
        return NetworkInterface.GetAllNetworkInterfaces()
            .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up &&
                              adapter.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .Select(adapter => adapter.GetIPProperties())
            .OrderByDescending(properties => properties.GatewayAddresses.Any(
                gateway => gateway.Address.AddressFamily == AddressFamily.InterNetwork &&
                           !gateway.Address.Equals(IPAddress.Any)))
            .SelectMany(properties => properties.UnicastAddresses)
            .Select(item => item.Address)
            .FirstOrDefault(ip => ip.AddressFamily == AddressFamily.InterNetwork &&
                                  !IPAddress.IsLoopback(ip) && !ip.ToString().StartsWith("169.254."))?.ToString()
            ?? "127.0.0.1";
    }

    private static string Authority(string address, int port, bool url)
    {
        if (address.Contains(':'))
            address = "[" + (url ? address.Replace("%", "%25") : address) + "]";
        return address + ":" + port;
    }
}

internal sealed record InterfaceAddress(string Address, string Label)
{
    public override string ToString() => Label;
}
