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

    /// Préfixe de l'agrégat privé créé par SystemAudioRecorder : visible depuis
    /// notre propre process, il n'a rien à faire dans le sélecteur de micro.
    private static let ownAggregatePrefix = "com.cletetour.sillage.agg."

    static func inputDevices() -> [AudioInputDevice] {
        guard let ids = allDeviceIDs() else { return [] }
        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            guard !uid.hasPrefix(ownAggregatePrefix) else { return nil }
            return AudioInputDevice(id: id, name: name, uid: uid)
        }
    }

    /// Nom lisible d'un périphérique — utilisé dans les logs, où un simple
    /// AudioDeviceID ne permet pas de savoir quel micro a servi.
    static func name(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    /// Appelle `handler` sur la file principale à chaque branchement ou
    /// débranchement de périphérique. L'observation dure toute la vie de l'app.
    static func observeDeviceChanges(_ handler: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
                handler()
            }
        if status != noErr {
            Log.app.error("Écoute des périphériques indisponible (status \(status, privacy: .public))")
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
