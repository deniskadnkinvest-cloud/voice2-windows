using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace Voice2;

public partial class FloatingPill : Window
{
    public static readonly FloatingPill Instance = new();
    private readonly DispatcherTimer _hideTimer = new() { Interval = TimeSpan.FromSeconds(2.5) };

    private FloatingPill()
    {
        InitializeComponent();
        PositionBottomCenter();
        _hideTimer.Tick += (_, _) => { _hideTimer.Stop(); Hide(); };
    }

    private void PositionBottomCenter()
    {
        var screen = SystemParameters.WorkArea;
        Left = (screen.Width - Width) / 2;
        Top  = screen.Bottom - Height - 32;
    }

    public void ShowRecording()
    {
        _hideTimer.Stop();
        Dispatcher.Invoke(() =>
        {
            Label.Text = "● Запись…";
            Pill.Background = new SolidColorBrush(Color.FromArgb(0xCC, 0x1C, 0x1C, 0x1E));
            Show();
        });
    }

    public void ShowTranscribing()
    {
        Dispatcher.Invoke(() =>
        {
            Label.Text = "◌ Распознаю…";
        });
    }

    public void ShowResult(string text)
    {
        _hideTimer.Stop();
        Dispatcher.Invoke(() =>
        {
            string preview = text.Length > 40 ? text[..40] + "…" : text;
            Label.Text = $"✓ {preview}";
            Pill.Background = new SolidColorBrush(Color.FromArgb(0xCC, 0x1C, 0x44, 0x1E));
        });
        _hideTimer.Start();
    }

    public void ShowError(string msg)
    {
        _hideTimer.Stop();
        Dispatcher.Invoke(() =>
        {
            Label.Text = $"✗ {msg}";
            Pill.Background = new SolidColorBrush(Color.FromArgb(0xCC, 0x55, 0x10, 0x10));
            Show();
        });
        _hideTimer.Start();
    }

    private void OnDrag(object sender, System.Windows.Input.MouseButtonEventArgs e) => DragMove();
}
