# Third-party components

RTMP Live Desk dynamically loads LibVLC through LibVLCSharp and runs MediaMTX as a separate process. The following upstream licenses apply to those components.

- **MediaMTX v1.21.3** uses the MIT license. The installer includes the upstream notice in `server/LICENSE`. [Release and source](https://github.com/bluenviron/mediamtx/releases/tag/v1.21.3)
- **VLC 3.0.24 for Windows x64** supplies LibVLC and its loadable modules. LibVLC is LGPL-licensed and VLC modules have their own licenses. The installer includes the VLC distribution's `vlc/COPYING.txt`. The corresponding source distribution contains the module notices and Windows build files. [Binary archive](https://download.videolan.org/pub/videolan/vlc/3.0.24/win64/vlc-3.0.24-win64.zip) · [Corresponding source](https://download.videolan.org/pub/videolan/vlc/3.0.24/vlc-3.0.24.tar.xz)
- **LibVLCSharp and LibVLCSharp.WinForms 3.10.2** are VideoLAN's LGPL-2.1-or-later .NET bindings. [Package and license](https://www.nuget.org/packages/LibVLCSharp.WinForms/3.10.2) · [Corresponding source](https://code.videolan.org/videolan/LibVLCSharp/-/tree/3082c09ca955131c705fc4767fde03e9c4a14999)
- **.NET 10.0.14 and Windows Forms** are published with the application as a self-contained runtime. The installer includes upstream notices in `licenses`. [Runtime source](https://github.com/dotnet/runtime/tree/v10.0.14) · [Windows Forms source](https://github.com/dotnet/winforms/tree/v10.0.14)
