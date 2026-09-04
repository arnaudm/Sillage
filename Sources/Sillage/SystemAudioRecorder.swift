import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Capture le son de sortie système via **Core Audio process taps** (macOS 14.2+).
/// Piste séparée = « eux » (interlocuteurs dans Zoom/Meet/etc.).
///
/// Permission « sons du système uniquement » (comme Granola), pas d'écran.
///
/// Alignement temporel : macOS met le device en veille pendant les silences, et
/// le tap ne livre des buffers QUE quand du son joue. Sans rien faire, la piste
/// commencerait au premier son et les silences seraient supprimés → décalage.
/// On reconstruit donc la vraie timeline : à chaque buffer, on calcule le temps
/// écoulé depuis le démarrage (horloge `mach`) et on insère le silence manquant
/// avant d'écrire → piste continue, alignée sur le micro.
final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var firstSampleLogged = false
    private let ioQueue = DispatchQueue(label: "com.cletetour.sillage.tap-io")

    // Reconstruction de la timeline.
    private var startHostTime: UInt64 = 0
    private var framesWritten: Int64 = 0
    private var timebase = mach_timebase_info_data_t()

    func start(to url: URL) async throws {
        firstSampleLogged = false
        framesWritten = 0
        mach_timebase_info(&timebase)

        // 1) Tap global stéréo de tout le son système.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "Sillage"
        tapDescription.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard status == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            throw fail("AudioHardwareCreateProcessTap", status)
        }
        tapID = tap
        Log.system.notice("Process tap créé (id \(tap, privacy: .public))")

        // 2) Format réel du tap.
        guard var asbd = Self.tapFormat(tap),
              let fmt = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw fail("Lecture du format du tap", -1)
        }
        format = fmt

        // 3) Device agrégé privé contenant le tap.
        let aggUID = "com.cletetour.sillage.agg.\(tapDescription.uuid.uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sillage Aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard status == noErr, agg != AudioObjectID(kAudioObjectUnknown) else {
            cleanup()
            throw fail("AudioHardwareCreateAggregateDevice", status)
        }
        aggregateID = agg

        // 4) Fichier au format du tap (même entrelacement, sinon write -50).
        file = try AVAudioFile(forWriting: url,
                               settings: fmt.settings,
                               commonFormat: .pcmFormatFloat32,
                               interleaved: fmt.isInterleaved)

        // 5) IOProc (on récupère l'horodatage d'entrée pour l'alignement).
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            self?.handle(inInputData, inInputTime)
        }
        guard status == noErr, let procID else {
            cleanup()
            throw fail("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        ioProcID = procID

        // 6) Démarrage : on fige l'instant de référence juste avant.
        startHostTime = mach_absolute_time()
        status = AudioDeviceStart(agg, procID)
        guard status == noErr else {
            cleanup()
            throw fail("AudioDeviceStart", status)
        }
        Log.system.notice("Capture son système démarrée (\(fmt.sampleRate, privacy: .public) Hz, \(fmt.channelCount, privacy: .public) ch)")
    }

    private func handle(_ inInputData: UnsafePointer<AudioBufferList>,
                        _ inInputTime: UnsafePointer<AudioTimeStamp>) {
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData)
        else { return }
        let incoming = Int64(buffer.frameLength)
        guard incoming > 0 else { return }

        // Position réelle (en frames) où doit se terminer ce buffer.
        let host = inInputTime.pointee.mHostTime
        let nowHost = host != 0 ? host : mach_absolute_time()
        let elapsed = nowHost > startHostTime ? hostToSeconds(nowHost - startHostTime) : 0
        let target = Int64(elapsed * format.sampleRate)

        // Combler le silence manquant avant ce buffer.
        let pad = target - incoming - framesWritten
        if pad > 0 { writeSilence(frames: pad) }

        do {
            if !firstSampleLogged {
                firstSampleLogged = true
                Log.system.notice("Premier échantillon système reçu (silence comblé: \(max(0, pad), privacy: .public) frames)")
            }
            try file?.write(from: buffer)
            framesWritten += incoming
        } catch {
            Log.system.error("Erreur d'écriture : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Écrit `frames` échantillons de silence (par blocs pour borner la mémoire).
    private func writeSilence(frames: Int64) {
        guard frames > 0, let format, let file else { return }
        var remaining = frames
        let chunk: AVAudioFrameCount = 48_000
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, Int64(chunk)))
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            buf.frameLength = n
            for b in UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList) {
                if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
            }
            do { try file.write(from: buf) } catch {
                Log.system.error("Erreur d'écriture (silence) : \(error.localizedDescription, privacy: .public)")
                return
            }
            remaining -= Int64(n)
        }
        framesWritten += frames
    }

    private func hostToSeconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// true si le tap n'a jamais livré le moindre buffer : la piste produite est
    /// un simple en-tête WAV, inexploitable.
    private(set) var capturedNothing = false

    func stop() async {
        let frames = framesWritten
        capturedNothing = frames == 0
        cleanup()
        if capturedNothing {
            Log.system.error("Capture son système arrêtée SANS AUCUN échantillon — piste vide")
        } else {
            Log.system.notice("Capture son système arrêtée (\(frames, privacy: .public) frames)")
        }
    }

    private func cleanup() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        file = nil
        format = nil
    }

    private func fail(_ what: String, _ status: OSStatus) -> NSError {
        Log.system.error("\(what, privacy: .public) a échoué (status \(status, privacy: .public))")
        return NSError(domain: "Sillage.SystemAudio", code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: "\(what) a échoué (status \(status))"])
    }

    private static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        return status == noErr ? asbd : nil
    }
}
