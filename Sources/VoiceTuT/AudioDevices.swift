import Foundation
import CoreAudio
import AVFoundation

// Перечисление аудио-входов через Core Audio (HAL).
// Нужно чтобы VoiceTuT мог писать с КОНКРЕТНОГО устройства, а не с системного
// «по умолчанию» — иначе во время звонка дефолтный вход = AirPods (HFP),
// который занят звонком, и запись выходит тишиной.

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isBluetooth: Bool
}

enum AudioDevices {

    /// Все устройства, у которых есть входные каналы.
    static func inputDevices() -> [AudioInputDevice] {
        var result: [AudioInputDevice] = []
        for devID in allDeviceIDs() {
            guard deviceHasInput(devID) else { continue }
            let uid = stringProperty(devID, kAudioDevicePropertyDeviceUID) ?? ""
            let name = stringProperty(devID, kAudioObjectPropertyName)
                ?? stringProperty(devID, kAudioDevicePropertyDeviceNameCFString)
                ?? "Устройство \(devID)"
            let transport = transportType(devID)
            let isBuiltIn = transport == kAudioDeviceTransportTypeBuiltIn
                || uid == "BuiltInMicrophoneDevice"
            let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
            result.append(AudioInputDevice(
                id: devID, uid: uid, name: name,
                isBuiltIn: isBuiltIn, isBluetooth: isBluetooth
            ))
        }
        return result
    }

    static func builtInMic() -> AudioInputDevice? {
        let inputs = inputDevices()
        return inputs.first(where: { $0.uid == "BuiltInMicrophoneDevice" })
            ?? inputs.first(where: { $0.isBuiltIn })
    }

    static func systemDefaultInput() -> AudioInputDevice? {
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID
        )
        guard st == noErr, devID != 0 else { return nil }
        return inputDevices().first(where: { $0.id == devID })
    }

    static func device(forUID uid: String) -> AudioInputDevice? {
        inputDevices().first(where: { $0.uid == uid })
    }

    // MARK: - Core Audio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func deviceHasInput(_ devID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &addr, 0, nil, &size) == noErr, size > 0
        else { return false }
        let bufList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufList.deallocate() }
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, bufList) == noErr
        else { return false }
        let abl = bufList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        var channels = 0
        for b in buffers { channels += Int(b.mNumberChannels) }
        return channels > 0
    }

    private static func transportType(_ devID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &transport)
        return transport
    }

    private static func stringProperty(_ devID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let st = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, raw)
            }
        }
        guard st == noErr, let s = cfStr else { return nil }
        return s as String
    }
}
