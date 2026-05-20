using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Voice2;

public partial class MainWindow : Window
{
    private readonly AudioRecorder _recorder  = new();
    private readonly GlobalHotkey  _hotkey    = new();
    private readonly DispatcherTimer _pollTimer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private bool _isRecording;
    private int  _seconds;
    private DispatcherTimer? _secTimer;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        _pollTimer.Tick += (_, _) => _hotkey.PollRelease();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _hotkey.OnDown += () => Dispatcher.Invoke(StartRecording);
        _hotkey.OnUp   += () => Dispatcher.Invoke(StopRecording);
        bool ok = _hotkey.Start(this);
        UpdateHotkeyBadge(ok);
        _pollTimer.Start();
        RefreshUsageUI();
        Log("Perms  mic:? hotkey:" + (ok ? "✓" : "✗"));
    }

    // ── Recording ─────────────────────────────────────────────────

    private void StartRecording()
    {
        if (_isRecording) return;
        if (UsageTracker.Instance.IsLimitReached)
        {
            FloatingPill.Instance.ShowError("Лимит 2000 слов исчерпан");
            Log("🔒 Лимит free-плана исчерпан — нужна оплата");
            return;
        }
        if (!_recorder.Start())
        {
            FloatingPill.Instance.ShowError("Ошибка микрофона");
            Log("❌ Не удалось запустить аудиозапись");
            return;
        }
        _isRecording = true;
        _seconds     = 0;
        SetRecordingState(true);
        FloatingPill.Instance.ShowRecording();
        Log("▶ Запись началась");

        _secTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _secTimer.Tick += (_, _) => { _seconds++; Log($"  {_seconds}с…"); };
        _secTimer.Start();
    }

    private async void StopRecording()
    {
        if (!_isRecording) return;
        _isRecording = false;
        _secTimer?.Stop(); _secTimer = null;
        SetRecordingState(false);

        string? wav = _recorder.Stop();
        if (wav == null) { FloatingPill.Instance.ShowError("Нет аудио"); return; }

        Log("⏸ Остановлено, распознаю…");
        FloatingPill.Instance.ShowTranscribing();

        string? text = await WhisperRunner.RunAsync(wav);
        if (string.IsNullOrWhiteSpace(text))
        {
            Log("⚠️ Пустой результат (тишина?)");
            FloatingPill.Instance.ShowError("Тишина");
            return;
        }

        UsageTracker.Instance.AddWords(text);
        int used  = UsageTracker.Instance.WordsThisMonth;
        int limit = UsageTracker.FreeLimit;
        Log($"✅ \"{text[..Math.Min(60, text.Length)]}\"  [{used}/{limit} слов]");
        FloatingPill.Instance.ShowResult(text);
        RefreshUsageUI();
        await TextInjector.PasteAsync(text);
    }

    // ── UI helpers ─────────────────────────────────────────────────

    private void SetRecordingState(bool recording)
    {
        DotColor.Color = recording ? Colors.Red : Colors.Green;
        HeaderLabel.Text = recording ? "Диктую…" : "Voice 2.0";
        RecordBtn.Content = recording ? "● Отпусти для остановки" : "🎙  Зажми и говори";
        RecordBtn.Background = new SolidColorBrush(recording ? Colors.Red : Color.FromRgb(0, 122, 255));
    }

    private void RefreshUsageUI()
    {
        UsageLabel.Text = UsageTracker.Instance.StatusText;
    }

    private void UpdateHotkeyBadge(bool ok)
    {
        HotkeyBadge.Background = new SolidColorBrush(ok ? Color.FromRgb(220, 255, 220) : Color.FromRgb(255, 220, 220));
        HotkeyLabel.Text = ok ? "⌨ Right Ctrl ✓" : "⌨ Right Ctrl ✗";
        if (!ok)
        {
            PermHint.Text       = "Хоткей не зарегистрирован. Возможно, его уже занял другой процесс. Перезапусти Voice2 или измени хоткей в будущих настройках.";
            PermHint.Visibility = Visibility.Visible;
        }
    }

    private void Log(string msg)
    {
        string ts   = DateTime.Now.ToString("HH:mm:ss");
        string line = $"[{ts}] {msg}";
        LogBox.Items.Add(line);
        if (LogBox.Items.Count > 300) LogBox.Items.RemoveAt(0);
        LogBox.ScrollIntoView(LogBox.Items[^1]);
    }

    // ── Event handlers ─────────────────────────────────────────────

    private void OnRecordDown(object s, MouseButtonEventArgs e) { StartRecording(); e.Handled = true; }
    private void OnRecordUp(object s, MouseButtonEventArgs e)   { StopRecording();  e.Handled = true; }

    private void OnCheckPerms(object s, RoutedEventArgs e)
    {
        bool ok = _hotkey.IsActive;
        UpdateHotkeyBadge(ok);
        Log($"🔄 Проверено hotkey:{(ok ? "✓" : "✗")}");
    }

    private void OnClearLog(object s, RoutedEventArgs e) => LogBox.Items.Clear();

    // Minimize to tray on close instead of exiting
    private void OnClosing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }
}
