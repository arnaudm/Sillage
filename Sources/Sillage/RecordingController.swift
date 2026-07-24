import Foundation
import AVFoundation
import CoreAudio
import Combine

@MainActor
final class RecordingController: ObservableObject {
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedInputDeviceID: AudioDeviceID? = nil
    @Published var captureSystemAudio: Bool = true
    @Published var isRecording: Bool = false
    @Published var statusMessage: String? = nil
    @Published private(set) var elapsed: TimeInterval = 0

    private let micRecorder = MicRecorder()
    private var systemRecorder: SystemAudioRecorder?
    private let floatingStop = FloatingStopController()
    private var timer: Timer?
    private var startDate: Date?
    private(set) var sessionDir: URL?

    init() {
        refreshDevices()
    }

    var elapsedString: String {
        let s = Int(elapsed)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    func refreshDevices() {
        inputDevices = AudioDeviceManager.inputDevices()
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        do {
            let dir = try makeSessionDir()
            sessionDir = dir

            let micURL = dir.appendingPathComponent("mic.wav")
            try micRecorder.start(deviceID: selectedInputDeviceID, to: micURL)

            if captureSystemAudio {
                let sysURL = dir.appendingPathComponent("system.wav")
                let recorder = SystemAudioRecorder()
                systemRecorder = recorder
                Task {
                    do {
                        try await recorder.start(to: sysURL)
                    } catch {
                        self.statusMessage = "Son système indisponible : \(error.localizedDescription)"
                    }
                }
            }

            startDate = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }

            isRecording = true
            statusMessage = "Enregistrement en cours…"
            floatingStop.show(controller: self)
        } catch {
            statusMessage = "Erreur au démarrage : \(error.localizedDescription)"
        }
    }

    func stop() {
        floatingStop.hide()
        timer?.invalidate()
        timer = nil
        micRecorder.stop()

        let recorder = systemRecorder
        systemRecorder = nil
        isRecording = false
        let dir = sessionDir

        statusMessage = "Transcription en cours…"
        Task {
            await recorder?.stop()
            await self.transcribeSession(dir: dir)
        }
    }

    /// Transcrit les deux pistes de la session et écrit un transcript.md.
    /// NOTE : la suppression automatique des WAV interviendra une fois le CR
    /// (étape suivante) validé. Pour l'instant on conserve l'audio.
    private func transcribeSession(dir: URL?) async {
        guard let dir else { return }
        let micURL = dir.appendingPathComponent("mic.wav")
        let sysURL = dir.appendingPathComponent("system.wav")
        let locale = Locale(identifier: "fr-FR")
        let fm = FileManager.default

        do {
            var mic: [TranscriptSegment] = []
            var system: [TranscriptSegment] = []

            if fm.fileExists(atPath: micURL.path) {
                mic = try await Transcriber.transcribe(fileURL: micURL, locale: locale)
            }
            if fm.fileExists(atPath: sysURL.path) {
                system = try await Transcriber.transcribe(fileURL: sysURL, locale: locale)
            }

            let markdown = Transcriber.mergeToMarkdown(mic: mic, system: system, date: Date())
            let outURL = dir.appendingPathComponent("transcript.md")
            try markdown.write(to: outURL, atomically: true, encoding: .utf8)

            let count = mic.count + system.count
            Log.app.notice("Transcript écrit : \(outURL.path, privacy: .public) (\(count) segments)")

            // Contrainte projet : l'audio est supprimé une fois le transcript
            // réalisé (uniquement en cas de succès, pour ne pas perdre l'audio
            // si la transcription échoue).
            deleteAudio(at: [micURL, sysURL])
            statusMessage = "Transcript prêt (\(count) segments) · audio supprimé"
        } catch {
            statusMessage = "Échec transcription : \(error.localizedDescription)"
            Log.app.error("Échec transcription : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Supprime les fichiers audio de la session (le transcript est conservé).
    private func deleteAudio(at urls: [URL]) {
        let fm = FileManager.default
        for url in urls where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                Log.app.notice("Audio supprimé : \(url.lastPathComponent, privacy: .public)")
            } catch {
                Log.app.error("Échec suppression audio \(url.lastPathComponent, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeSessionDir() throws -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sillage/Recordings", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = base.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
