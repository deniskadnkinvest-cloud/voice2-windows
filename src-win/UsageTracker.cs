using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Text.Json;

namespace Voice2;

public sealed class UsageTracker : INotifyPropertyChanged
{
    public static readonly UsageTracker Instance = new();

    public const int FreeLimit = int.MaxValue; // unlimited — personal build
    private static readonly string DataPath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                     "Voice2", "usage.json");

    private int _wordsThisMonth = 0;

    public int    WordsThisMonth => _wordsThisMonth;
    public bool   IsLimitReached => false; // no limit
    public double Progress       => 0;
    public string StatusText     => "Безлимит";

    private UsageTracker() => Load();

    private string MonthKey => DateTime.Now.ToString("yyyy-MM");

    public void AddWords(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        int count = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        _wordsThisMonth += count;
        Save();
    }

    // ── Persistence ──────────────────────────────────────────────

    private void Load()
    {
        try
        {
            if (!File.Exists(DataPath)) return;
            var dict = JsonSerializer.Deserialize<Dictionary<string, string>>(
                           File.ReadAllText(DataPath)) ?? new();
            if (dict.TryGetValue(MonthKey, out var w) && int.TryParse(w, out var n))
                _wordsThisMonth = n;
        }
        catch { }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(DataPath)!);
            var dict = new Dictionary<string, string> { [MonthKey] = _wordsThisMonth.ToString() };
            File.WriteAllText(DataPath, JsonSerializer.Serialize(dict));
        }
        catch { }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Notify([System.Runtime.CompilerServices.CallerMemberName] string? p = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(p));
}
