using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace RtmpLiveDesk;

internal static class DeskChrome
{
    internal static GraphicsPath RoundedRectangle(Rectangle bounds, int radius)
    {
        var path = new GraphicsPath();
        var corner = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        path.AddArc(bounds.Left, bounds.Top, corner, corner, 180, 90);
        path.AddArc(bounds.Right - corner, bounds.Top, corner, corner, 270, 90);
        path.AddArc(bounds.Right - corner, bounds.Bottom - corner, corner, corner, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - corner, corner, corner, 90, 90);
        path.CloseFigure();
        return path;
    }

    internal static void ApplyCaption(IntPtr window, Color background, Color text)
    {
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17763))
        {
            var enabled = 1;
            DwmSetWindowAttribute(window, 20, ref enabled, sizeof(int));
        }
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            var caption = ColorTranslator.ToWin32(background);
            var foreground = ColorTranslator.ToWin32(text);
            DwmSetWindowAttribute(window, 35, ref caption, sizeof(int));
            DwmSetWindowAttribute(window, 36, ref foreground, sizeof(int));
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}

internal sealed class DeskCard : Panel
{
    private readonly Color border;

    internal DeskCard(Color background, Color border)
    {
        BackColor = background;
        this.border = border;
        DoubleBuffered = true;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(Parent?.BackColor ?? BackColor);
        if (Width < 3 || Height < 3) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = DeskChrome.RoundedRectangle(new Rectangle(0, 0, Width - 1, Height - 1), DeviceDpi * 14 / 96);
        using var fill = new SolidBrush(BackColor);
        using var edge = new Pen(border);
        e.Graphics.FillPath(fill, path);
        e.Graphics.DrawPath(edge, path);
    }
}

internal sealed class DeskButton : Button
{
    private readonly Color fill, ink, border, disabledInk;
    private bool hovered;

    internal DeskButton(string text, Color fill, Color ink, Color border, Color disabledInk)
    {
        Text = text;
        this.fill = fill;
        this.ink = ink;
        this.border = border;
        this.disabledInk = disabledInk;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        MinimumSize = new Size(62, 32);
        Padding = new Padding(10, 3, 10, 3);
        FlatStyle = FlatStyle.Flat;
        Cursor = Cursors.Hand;
        DoubleBuffered = true;
    }

    protected override void OnMouseEnter(EventArgs e)
    {
        base.OnMouseEnter(e);
        hovered = true;
        Invalidate();
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        hovered = false;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var background = Parent?.BackColor ?? fill;
        e.Graphics.Clear(background);
        if (Width < 3 || Height < 3) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = DeskChrome.RoundedRectangle(new Rectangle(0, 0, Width - 1, Height - 1), DeviceDpi * 7 / 96);
        using var brush = new SolidBrush(!Enabled ? background : hovered ? ControlPaint.Light(fill, 0.12F) : fill);
        using var edge = new Pen(Enabled ? border : ControlPaint.Dark(disabledInk, 0.35F));
        e.Graphics.FillPath(brush, path);
        e.Graphics.DrawPath(edge, path);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, Enabled ? ink : disabledInk,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        if (Focused && ShowFocusCues)
            ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -4, -4), ink, fill);
    }
}
