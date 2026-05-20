using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;

namespace Voice2;

// Injects text into the focused application via clipboard + Ctrl+V.
// Same strategy as the macOS version (clipboard + Cmd+V) — works in any application.
public static class TextInjector
{
    [DllImport("user32.dll")] private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    private const byte VK_CONTROL   = 0x11;
    private const byte VK_V         = 0x56;
    private const uint KEYEVENTF_KEYDOWN = 0;
    private const uint KEYEVENTF_KEYUP   = 0x0002;

    public static async Task PasteAsync(string text)
    {
        // Save previous clipboard content
        string? prev = null;
        Application.Current.Dispatcher.Invoke(() =>
        {
            try { prev = Clipboard.ContainsText() ? Clipboard.GetText() : null; } catch { }
            Clipboard.SetText(text);
        });

        await Task.Delay(60);

        // Send Ctrl+V
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYDOWN, UIntPtr.Zero);
        keybd_event(VK_V,       0, KEYEVENTF_KEYDOWN, UIntPtr.Zero);
        await Task.Delay(30);
        keybd_event(VK_V,       0, KEYEVENTF_KEYUP,   UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP,   UIntPtr.Zero);

        // Restore previous clipboard after a short delay
        await Task.Delay(600);
        if (prev != null)
            Application.Current.Dispatcher.Invoke(() =>
            {
                try { Clipboard.SetText(prev); } catch { }
            });
    }
}
