import Foundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// Énumération des périphériques d'entrée via Core Audio
/// (micro intégré, casque Bluetooth, interface externe…).
enum AudioDeviceManager {

    static func inputDevices() -> [AudioInputDevice] {
        guard let ids = allDeviceIDs() else { return [] }
        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            return AudioInputDevice(id: id, name: name, uid: uid)
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID]? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids
    }

    /// Un périphérique est une "entrée" s'il expose au moins un canal sur le scope Input.
    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }

        let ablPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ablPtr) == noErr else { return false }

        let abl = UnsafeMutableAudioBufferListPointer(
            ablPtr.assumingMemoryBound(to: AudioBufferList.self))
        for buffer in abl where buffer.mNumberChannels > 0 { return true }
        return false
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let s = cfStr else { return nil }
        return s as String
    }
}
