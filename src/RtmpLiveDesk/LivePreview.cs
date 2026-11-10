using LibVLCSharp.Shared;

namespace RtmpLiveDesk;

internal static class LivePreview
{
    internal static LibVLC CreateEngine() => new(
        "--ignore-config", "--no-video-title-show", "--rtsp-tcp",
        "--network-caching=50", "--clock-jitter=0", "--drop-late-frames");
}
