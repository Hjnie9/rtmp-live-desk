# RTMP Live Desk

RTMP Live Desk 把 RTMP 服务、推流设置和实时预览放进一个 Flutter 桌面窗口。安装包内置 MediaMTX 和 libmpv。

## 安装和使用

1. 下载适合电脑架构的 Windows x64 或 ARM64 MSI。在向导中选择安装目录、开始菜单入口和桌面快捷方式。[GitHub Releases](https://github.com/Hjnie9/rtmp-live-desk/releases/latest)
2. 选择监听地址、端口和串流密钥，再点击「启动」。初始设置监听所有地址，端口为 `1935`。已有安装会读取当前用户原来的设置。
3. 把界面显示的服务器地址和串流密钥填入 OBS 或推流设备。收到推流后，窗口会自动接入实时画面。
4. 点击全屏按钮、双击画面或按 `F11` 进入全屏，按 `Esc` 退出。顶部「日志」可以展开或隐藏服务日志。

预览从本机 RTSP 读取实时流，并关闭播放器的预读缓存。纯视频流使用即时显示，有音频的流继续同步音画。可用「回到直播」重新接入当前流。

## 从源码构建

Windows 打包需要 Flutter 3.47.9、Visual Studio 的 Desktop development with C++ 工作负载、.NET SDK 和 WiX 6.0.2。使用与目标架构一致的 Windows 和 Dart SDK。ARM64 还需要 Go 1.27.0 来编译 MediaMTX。[Flutter Windows 开发环境](https://docs.flutter.dev/platform-integration/windows/setup)

```powershell
.\scripts\Build-Windows.ps1 -Architecture x64
```

ARM64 构建使用 `-Architecture arm64`。脚本按锁文件恢复依赖，打包目标架构的 Flutter 应用、播放器和 MediaMTX，安装包位于 `artifacts`。GitHub Actions 的 **Windows installers** 流程运行同一脚本。第三方许可和源码信息见 [THIRD-PARTY.md](THIRD-PARTY.md)。

## 平台结构

- `lib/` 包含 Flutter 界面、预览控制和 RTMP 服务接口。Windows 和 Linux 共用 MediaMTX 进程适配层。
- Linux runner 已纳入仓库。构建后需把对应架构的 MediaMTX 放在可执行文件旁的 `server/mediamtx`，并提供 Linux libmpv 运行库。
- Android runner 可作为移植起点。本机推流服务需要 Android 实现。鸿蒙版还需要适用的 Flutter 工具链、原生播放器和推流服务适配。
