# RTMP Live Desk

Windows x64 桌面程序，用于启动 RTMP 服务、管理串流密钥并在同一窗口观看实时画面。播放器通过 LibVLC 读取本机 RTSP 流，使用 50 ms 网络缓存。直播界面提供声音开关和「回到直播」。

## 安装和使用

1. 在 Releases 下载当前版本的 `win-x64.msi`，安装后从开始菜单打开 **RTMP Live Desk**。
2. 选择监听地址和端口，按需要填写串流密钥，点击「启动」。默认监听所有网卡，端口为 `1935`。
3. 在 OBS 或推流设备填写窗口里显示的服务器和串流密钥。程序收到流后会在右侧自动播放。

运行中的设置变更通过「保存并应用」生效。设置保存在当前用户的本地应用数据目录。迁移已有服务时，先释放相同的 RTMP 端口，或在桌面程序里选择其他端口。

## 从源码构建

在 Windows x64 安装 .NET 10 SDK 和 WiX Toolset 6.0.2，确保 `dotnet.exe` 和 `wix.exe` 在 PATH 中，然后运行 PowerShell 脚本。

```powershell
.\scripts\Build-Windows.ps1
```

脚本会校验并提取 MediaMTX 和 LibVLC，生成自包含的 x64 应用和 MSI。安装包写到 `artifacts` 目录。有关第三方组件的许可证和对应源码，见 [THIRD-PARTY.md](THIRD-PARTY.md)。
