using System;
using System.IO;
using NAudio.Wave;

namespace Voice2;

// Records microphone input to a temp WAV file (16kHz mono 16-bit PCM).
// Matches the audio format expected by whisper.cpp.
public sealed class AudioRecorder : IDisposable
{
    private WaveInEvent?  _waveIn;
    private WaveFileWriter? _writer;
    private string?       _path;

    public bool IsRecording { get; private set; }

    public bool Start()
    {
        try
        {
            _path = Path.Combine(Path.GetTempPath(), $"voice2_{Guid.NewGuid():N}.wav");
            _waveIn = new WaveInEvent
            {
                WaveFormat      = new WaveFormat(16000, 16, 1),
                BufferMilliseconds = 50
            };
            _writer = new WaveFileWriter(_path, _waveIn.WaveFormat);
            _waveIn.DataAvailable += (_, e) => _writer?.Write(e.Buffer, 0, e.BytesRecorded);
            _waveIn.StartRecording();
            IsRecording = true;
            return true;
        }
        catch
        {
            Cleanup();
            return false;
        }
    }

    public string? Stop()
    {
        if (!IsRecording) return null;
        IsRecording = false;
        _waveIn?.StopRecording();
        _writer?.Flush();
        _writer?.Dispose();
        _writer = null;
        _waveIn?.Dispose();
        _waveIn = null;
        return _path;
    }

    private void Cleanup()
    {
        _writer?.Dispose(); _writer = null;
        _waveIn?.Dispose(); _waveIn = null;
        IsRecording = false;
    }

    public void Dispose() => Cleanup();
}
