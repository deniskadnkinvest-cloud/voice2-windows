using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;

namespace Voice2;

public static class WhisperRunner
{
    // With PublishSingleFile, BaseDirectory is a temp extraction folder.
    // whisper.exe and model are always next to Voice2.exe in the install dir.
    private static string AppDir =>
        Path.GetDirectoryName(Environment.ProcessPath ?? AppDomain.CurrentDomain.BaseDirectory)
        ?? AppDomain.CurrentDomain.BaseDirectory;

    private static string WhisperExe => Path.Combine(AppDir, "whisper.exe");
    private static string ModelBin   => Path.Combine(AppDir, "ggml-base.bin");

    // Returns transcription or null on error / blank audio.
    public static Task<string?> RunAsync(string wavPath) => Task.Run(() =>
    {
        try
        {
            if (!File.Exists(WhisperExe)) return null;
            var psi = new ProcessStartInfo(WhisperExe)
            {
                Arguments              = $"-m \"{ModelBin}\" -f \"{wavPath}\" -l ru --no-timestamps -nt",
                RedirectStandardOutput = true,
                RedirectStandardError  = true,
                UseShellExecute        = false,
                CreateNoWindow         = true
            };

            using var p = Process.Start(psi)!;
            string output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(60_000);

            string text = output
                .Replace("[BLANK_AUDIO]", "")
                .Replace("[музыка]", "")
                .Trim();

            return string.IsNullOrWhiteSpace(text) ? null : text;
        }
        catch { return null; }
        finally
        {
            try { if (File.Exists(wavPath)) File.Delete(wavPath); } catch { }
        }
    });
}
