using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Voice2;

// Registers Right Ctrl as a global push-to-talk hotkey using Win32 RegisterHotKey.
// Right Ctrl (VK_RCONTROL 0xA3) has no conflicts on RU/EN keyboard layouts,
// unlike Right Alt which equals AltGr on non-EN-US layouts.
public sealed class GlobalHotkey : IDisposable
{
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int WM_HOTKEY   = 0x0312;
    private const int WM_KEYDOWN  = 0x0100;
    private const int WM_KEYUP    = 0x0101;
    private const uint VK_RCONTROL = 0xA3;
    private const uint MOD_NONE   = 0x0000;
    private const int HotkeyId    = 9001;

    private HwndSource? _source;
    private bool        _isDown;

    public event Action? OnDown;
    public event Action? OnUp;

    public bool IsActive { get; private set; }

    public bool Start(Window owner)
    {
        var helper = new WindowInteropHelper(owner);
        _source = HwndSource.FromHwnd(helper.EnsureHandle());
        _source.AddHook(WndProc);

        IsActive = RegisterHotKey(helper.Handle, HotkeyId, MOD_NONE, VK_RCONTROL);
        return IsActive;
    }

    public void Stop()
    {
        if (_source == null) return;
        UnregisterHotKey(_source.Handle, HotkeyId);
        _source.RemoveHook(WndProc);
        IsActive = false;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && wParam.ToInt32() == HotkeyId)
        {
            // lParam low word = repeat count; high word = extended key flags.
            // We detect key-down vs key-up via our own _isDown toggle because
            // RegisterHotKey fires only on WM_HOTKEY (down edge); we use
            // GetAsyncKeyState to check if the key is still physically held.
            if (!_isDown)
            {
                _isDown = true;
                OnDown?.Invoke();
            }
            else
            {
                _isDown = false;
                OnUp?.Invoke();
            }
            handled = true;
        }
        return IntPtr.Zero;
    }

    // Raw keyboard hook alternative: poll release via a DispatcherTimer.
    // RegisterHotKey only fires key-down. We detect release by polling GetAsyncKeyState.
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);

    public void PollRelease()
    {
        if (!_isDown) return;
        short state = GetAsyncKeyState((int)VK_RCONTROL);
        if ((state & 0x8000) == 0)
        {
            _isDown = false;
            OnUp?.Invoke();
        }
    }

    public void Dispose() => Stop();
}
