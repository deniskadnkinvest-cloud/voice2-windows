import AVFoundation
import CoreAudio

// Запись с выбором устройства ввода.
//
// ДВА пути:
//  1. deviceID == nil (системный вход по умолчанию) → простой AVAudioRecorder.
//     Это рок-солид путь, который никогда не зависал. Используется в обычном случае.
//  2. deviceID != nil (нужно ПЕРЕОПРЕДЕЛИТЬ устройство, напр. во время звонка
//     AirPods-дефолт → встроенный микрофон) → AVAudioEngine с явным AudioDeviceID.
//     ВЕСЬ HAL/CoreAudio-код выполняется на ФОНОВОЙ serial-очереди — иначе обращение
//     к inputFormat во время реконфигурации устройства дедлочит главный поток
//     (баг 2026-06-02: UI замерзал, окно не открывалось, 39% CPU на HAL-мьютексе).

final class Recorder {
    private(set) var currentURL: URL?

    // Серийная очередь для ВСЕХ операций AVAudioEngine/CoreAudio — никогда не main.
    private let audioQueue = DispatchQueue(label: "com.voicetut.audio", qos: .userInitiated)

    // AVAudioEngine path
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var usingEngine = false

    // Fallback / default path
    private var legacyRecorder: AVAudioRecorder?

    private let peakLock = NSLock()
    private var enginePeak: Float = -160

    /// deviceID nil = системный дефолт (AVAudioRecorder). Иначе AVAudioEngine на фоне.
    func start(deviceID: AudioDeviceID? = nil) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        currentURL = url

        guard let devID = deviceID else {
            // Обычный путь — синхронный, быстрый, безопасный.
            usingEngine = false
            if startLegacy(url: url) { return true }
            currentURL = nil
            return false
        }

        // Путь с переопределением устройства — движок на фоне, main не блокируем.
        usingEngine = true
        enginePeak = -160
        audioQueue.async { [weak self] in
            guard let self else { return }
            if !self.startEngine(url: url, deviceID: devID) {
                // Движок не поднялся — откатываемся на дефолтный recorder (тоже на этой очереди).
                print("[Recorder] Engine failed → fallback to default AVAudioRecorder")
                self.usingEngine = false
                _ = self.startLegacy(url: url)
            }
        }
        // Оптимистично: файл будет наполнен с фоновой очереди. URL уже есть.
        return true
    }

    // MARK: - AVAudioEngine path (выполняется ТОЛЬКО на audioQueue)

    private func startEngine(url: URL, deviceID: AudioDeviceID) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let unit = input.audioUnit {
            var id = deviceID
            let st = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if st != noErr { print("[Recorder] setDevice failed: \(st)") }
        }

        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0 else {
            print("[Recorder] invalid input format")
            return false
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        ), let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            return false
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url, settings: fileSettings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
        } catch {
            print("[Recorder] AVAudioFile failed: \(error)")
            return false
        }

        self.converter = conv
        self.audioFile = file

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.processTapBuffer(buffer, inFormat: inFormat, outFormat: outFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[Recorder] engine.start failed: \(error)")
            input.removeTap(onBus: 0)
            self.converter = nil
            self.audioFile = nil
            return false
        }
        self.engine = engine
        print("[Recorder] Engine started (device \(deviceID))")
        return true
    }

    private func processTapBuffer(_ buffer: AVAudioPCMBuffer, inFormat: AVAudioFormat, outFormat: AVAudioFormat) {
        guard let conv = converter, let file = audioFile else { return }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }

        var consumed = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, inStatus in
            if consumed { inStatus.pointee = .noDataNow; return nil }
            consumed = true; inStatus.pointee = .haveData; return buffer
        }
        guard status != .error, outBuf.frameLength > 0 else { return }

        if let ch = outBuf.floatChannelData {
            let n = Int(outBuf.frameLength)
            var maxAbs: Float = 0
            let p = ch[0]
            for i in 0..<n { let v = abs(p[i]); if v > maxAbs { maxAbs = v } }
            let db = maxAbs > 0 ? 20 * log10(maxAbs) : -160
            peakLock.lock(); if db > enginePeak { enginePeak = db }; peakLock.unlock()
        }
        try? file.write(from: outBuf)
    }

    // MARK: - Default AVAudioRecorder path

    private func startLegacy(url: URL) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            r.record()
            legacyRecorder = r
            return true
        } catch {
            print("[Recorder] legacy failed: \(error)")
            return false
        }
    }

    // MARK: - Public

    func peakPower() -> Float? {
        if usingEngine {
            peakLock.lock(); defer { peakLock.unlock() }
            return enginePeak
        }
        guard let r = legacyRecorder else { return nil }
        r.updateMeters()
        return r.peakPower(forChannel: 0)
    }

    func stop() -> URL? {
        let url = currentURL
        currentURL = nil

        if usingEngine {
            // Тэрдаун движка и закрытие файла — на audioQueue, с ограниченным ожиданием,
            // чтобы whisper не прочитал недописанный WAV. main не зависнет: ждём максимум 2с.
            let sem = DispatchSemaphore(value: 0)
            audioQueue.async { [weak self] in
                self?.engine?.inputNode.removeTap(onBus: 0)
                self?.engine?.stop()
                self?.engine = nil
                self?.converter = nil
                self?.audioFile = nil   // закрытие финализирует WAV
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 2.0)
        } else {
            legacyRecorder?.stop()
            legacyRecorder = nil
        }
        return url
    }
}
