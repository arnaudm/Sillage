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
    /// Format d'écriture : identique à `format`, sauf pour une barrette de
    /// micros (> 2 canaux) où l'on réduit à un mono.
    private var fileFormat: AVAudioFormat?
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
        let name = AudioDeviceManager.name(of: dev) ?? "device \(dev)"
        let (status0, read) = Self.inputFormat(dev)
        var asbd = read
        guard status0 == noErr else {
            throw fail("Lecture du format d'entrée de « \(name) »", status0)
        }
        guard let fmt = Self.makeFormat(&asbd) else {
            throw fail("Format d'entrée inexploitable sur « \(name) » : \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) canaux")
        }
        format = fmt

        // 3) Fichier au format réel du device (même entrelacement que les
        //    buffers) — sauf pour une barrette de micros (> 2 canaux, ex. le
        //    micro intégré des MacBook et ses 3 capsules) : un WAV multicanal
        //    n'apporte rien à la transcription, on écrit donc un mono.
        let isArray = fmt.channelCount > 2
        guard let out = isArray ? Self.monoFormat(sampleRate: fmt.sampleRate) : fmt else {
            throw fail("Création du format mono impossible (\(fmt.sampleRate) Hz)")
        }
        guard !isArray || fmt.commonFormat == .pcmFormatFloat32 else {
            throw fail("Réduction en mono impossible : le device n'est pas en float32")
        }
        fileFormat = out
        file = try AVAudioFile(forWriting: url,
                               settings: out.settings,
                               commonFormat: .pcmFormatFloat32,
                               interleaved: out.isInterleaved)

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
        Log.mic.notice("Micro démarré : « \(name, privacy: .public) » (device \(dev, privacy: .public), \(fmt.sampleRate, privacy: .public) Hz, \(fmt.channelCount, privacy: .public) ch → fichier \(out.channelCount, privacy: .public) ch)")
    }

    private func write(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let format, let fileFormat,
              let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData)
        else { return }
        guard let buffer = fileFormat === format ? source : Self.firstChannel(of: source, as: fileFormat),
              buffer.frameLength > 0
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

    /// Extrait le premier canal d'une barrette de micros.
    /// Moyenner les capsules — espacées de plusieurs centimètres — créerait un
    /// filtrage en peigne dans la voix ; un seul capteur reste propre.
    private static func firstChannel(of source: AVAudioPCMBuffer,
                                     as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(source.frameLength)
        guard frames > 0,
              let input = source.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: source.frameLength),
              let output = out.floatChannelData?[0]
        else { return nil }
        out.frameLength = source.frameLength
        // `stride` vaut le nombre de canaux si les échantillons sont entrelacés
        // (cas du micro intégré), 1 si les canaux sont dans des buffers séparés.
        let step = source.stride
        let channel = input[0]
        for i in 0..<frames { output[i] = channel[i * step] }
        return out
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
        fileFormat = nil
    }

    private func fail(_ message: String) -> NSError {
        Log.mic.error("\(message, privacy: .public)")
        return NSError(domain: "Sillage.Mic", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: message])
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

    private static func inputFormat(_ dev: AudioDeviceID) -> (OSStatus, AudioStreamBasicDescription) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &asbd)
        return (status, asbd)
    }

    /// `AVAudioFormat(streamDescription:)` renvoie **nil** dès que le device
    /// expose plus de 2 canaux : sans layout, il ne sait pas déduire la
    /// disposition des canaux. C'est le cas du micro intégré des MacBook
    /// (barrette de 3 capsules) → on fournit un layout « canaux discrets ».
    private static func makeFormat(_ asbd: inout AudioStreamBasicDescription) -> AVAudioFormat? {
        guard asbd.mChannelsPerFrame > 2 else {
            return AVAudioFormat(streamDescription: &asbd)
        }
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
    }

    private static func monoFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: 1,
                      interleaved: false)
    }
}
