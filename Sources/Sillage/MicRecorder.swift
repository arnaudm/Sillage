import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Capture le micro (ou tout périphérique d'entrée choisi) via un IOProc
/// Core Audio et écrit un WAV. Piste séparée = « moi ».
///
/// On a délibérément abandonné AVAudioEngine ici : forcer un périphérique
/// d'entrée précis y est très fragile (format périmé → aucun buffer, ou échec
/// de négociation -10868). Lire directement le device en Core Audio est fiable,
/// et cohérent avec `SystemAudioRecorder`. Le fichier est créé au format réel
/// du device → pas d'accélération, quel que soit le débit (ex. Bluetooth 16 kHz).
final class MicRecorder {
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var firstSampleLogged = false
    private let ioQueue = DispatchQueue(label: "com.cletetour.sillage.mic-io")

    func start(deviceID chosen: AudioDeviceID?, to url: URL) throws {
        firstSampleLogged = false

        // 1) Device : celui choisi, sinon l'entrée par défaut du système.
        let dev = (chosen != nil && chosen != AudioObjectID(kAudioObjectUnknown))
            ? chosen!
            : (Self.defaultInputDevice() ?? AudioObjectID(kAudioObjectUnknown))
        guard dev != AudioObjectID(kAudioObjectUnknown) else {
            throw fail("Aucun périphérique d'entrée", -1)
        }
        deviceID = dev

        // 2) Format d'entrée réel du device.
        guard var asbd = Self.inputFormat(dev),
              let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw fail("Lecture du format d'entrée", -1)
        }
        format = fmt

        // 3) Fichier au format réel (même entrelacement que les buffers).
        file = try AVAudioFile(forWriting: url,
                               settings: fmt.settings,
                               commonFormat: .pcmFormatFloat32,
                               interleaved: fmt.isInterleaved)

        // 4) IOProc : reçoit les buffers d'entrée et les écrit.
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.write(inInputData)
        }
        guard status == noErr, let procID else {
            cleanup()
            throw fail("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        ioProcID = procID

        // 5) Démarrage.
        status = AudioDeviceStart(dev, procID)
        guard status == noErr else {
            cleanup()
            throw fail("AudioDeviceStart", status)
        }
        Log.mic.notice("Micro démarré (device \(dev, privacy: .public), \(fmt.sampleRate, privacy: .public) Hz, \(fmt.channelCount, privacy: .public) ch)")
    }

    private func write(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData)
        else { return }
        do {
            if !firstSampleLogged {
                firstSampleLogged = true
                Log.mic.notice("Premier échantillon micro reçu → écriture OK")
            }
            try file?.write(from: buffer)
        } catch {
            Log.mic.error("Erreur d'écriture : \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        cleanup()
        Log.mic.notice("Micro arrêté")
    }

    private func cleanup() {
        if deviceID != AudioObjectID(kAudioObjectUnknown), let procID = ioProcID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        file = nil
        format = nil
    }

    private func fail(_ what: String, _ status: OSStatus) -> NSError {
        Log.mic.error("\(what, privacy: .public) a échoué (status \(status, privacy: .public))")
        return NSError(domain: "Sillage.Mic", code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: "\(what) a échoué (status \(status))"])
    }

    // MARK: - Helpers Core Audio

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &dev)
        return status == noErr ? dev : nil
    }

    private static func inputFormat(_ dev: AudioDeviceID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &asbd)
        return status == noErr ? asbd : nil
    }
}
