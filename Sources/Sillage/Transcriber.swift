import Foundation
import Speech
import AVFoundation
import CoreMedia

/// Un segment de transcription : texte + instant de début (secondes).
struct TranscriptSegment: Sendable {
    let start: Double
    let text: String
}

/// Locuteur, déduit de la piste (micro = moi, système = interlocuteur).
enum Speaker: String, Sendable {
    case me = "Moi"
    case other = "Interlocuteur"
}

struct LabeledSegment: Sendable {
    let start: Double
    let speaker: Speaker
    let text: String
}

/// Étape en cours d'une transcription, pour l'affichage de l'avancement.
enum TranscriptionStage: Sendable {
    /// Téléchargement du modèle de langue, avec sa fraction si elle est connue.
    case installingModel(Double?)
    /// Position atteinte dans l'audio, de 0 à 1.
    case analyzing(Double)
}

enum TranscriptionError: LocalizedError {
    case localeUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let identifier):
            return "La transcription n'est pas disponible pour la langue \(identifier) sur ce Mac."
        }
    }
}

/// Transcription on-device via SpeechAnalyzer/SpeechTranscriber (macOS 26).
enum Transcriber {

    /// Transcrit un fichier audio complet et renvoie ses segments datés.
    /// `onStage` est appelé hors du MainActor, au fil des résultats.
    static func transcribe(fileURL: URL,
                           locale: Locale,
                           onStage: (@Sendable (TranscriptionStage) -> Void)? = nil)
    async throws -> [TranscriptSegment] {
        // Résoudre une locale réellement supportée (ex. fr-FR).
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)

        try await prepareModel(for: transcriber, locale: resolved, onStage: onStage)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: fileURL)

        // Durée totale de la piste : dénominateur de l'avancement.
        let sampleRate = audioFile.fileFormat.sampleRate
        let totalDuration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0

        // Une piste vide (0 frame) bloque l'analyseur : finalizeAndFinish…
        // attend une entrée qui n'arrivera jamais. On sort avant.
        guard audioFile.length > 0 else {
            Log.app.notice("\(fileURL.lastPathComponent, privacy: .public) est vide (0 frame) — piste ignorée")
            onStage?(.analyzing(1))
            return []
        }

        // Quitter l'étape « installation » dès maintenant : une piste sans
        // parole n'émet aucun résultat, et l'écran resterait bloqué dessus.
        onStage?(.analyzing(0))
        Log.app.notice("""
            Analyse de \(fileURL.lastPathComponent, privacy: .public) : \
            \(String(format: "%.1f", totalDuration), privacy: .public) s, \
            \(sampleRate, privacy: .public) Hz, \
            \(audioFile.fileFormat.channelCount, privacy: .public) ch
            """)

        // La séquence de résultats est Sendable → on peut la consommer dans une Task
        // concurrente pendant que l'analyse alimente le moteur.
        let resultsSequence = transcriber.results
        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in resultsSequence {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                segments.append(TranscriptSegment(start: start.isFinite ? start : 0, text: text))

                // L'avancement est la position du segment dans la piste : une
                // vraie fraction du travail, pas une animation.
                if totalDuration > 0, let onStage {
                    let end = result.range.end.seconds
                    let position = end.isFinite ? end : (start.isFinite ? start : 0)
                    onStage(.analyzing(min(1, max(0, position / totalDuration))))
                }
            }
            return segments
        }
        // Task non structurée : rien ne l'arrête si l'on quitte par une erreur
        // levée plus bas. Sur le chemin nominal, .value a déjà été attendu.
        defer { collector.cancel() }

        // Trois étapes distinctes, tracées séparément : sans ça, un blocage ne
        // se distingue pas d'une analyse lente.
        _ = try await analyzer.analyzeSequence(from: audioFile)
        Log.app.notice("Séquence analysée : \(fileURL.lastPathComponent, privacy: .public)")

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        Log.app.notice("Analyse finalisée : \(fileURL.lastPathComponent, privacy: .public)")

        // Annuler le collecteur si l'appelant abandonne pendant l'attente :
        // le defer ci-dessus ne s'exécuterait qu'une fois .value revenu.
        let segments = try await withTaskCancellationHandler {
            try await collector.value
        } onCancel: {
            collector.cancel()
        }
        Log.app.notice("\(fileURL.lastPathComponent, privacy: .public) : \(segments.count, privacy: .public) segments")
        return segments
    }

    /// S'assure que le modèle de langue est présent, en ne téléchargeant que si
    /// nécessaire. Le modèle est un *asset système* géré par macOS, pas une
    /// dépendance de l'app : on ne peut que constater son état et le demander.
    private static func prepareModel(for transcriber: SpeechTranscriber,
                                     locale: Locale,
                                     onStage: (@Sendable (TranscriptionStage) -> Void)?) async throws {
        let identifier = locale.identifier(.bcp47)
        let status = await AssetInventory.status(forModules: [transcriber])
        Log.app.notice("Modèle \(identifier, privacy: .public) : \(String(describing: status), privacy: .public)")

        if status == .unsupported {
            throw TranscriptionError.localeUnsupported(identifier)
        }
        if status == .installed {
            await reserveLocale(locale)
            return
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            await reserveLocale(locale)
            return
        }

        Log.app.notice("Installation du modèle \(identifier, privacy: .public)…")
        onStage?(.installingModel(nil))

        // downloadAndInstall() ne notifie rien : on sonde son Progress. Seuls les
        // changements sont remontés, pour que l'absence d'avancement reste visible.
        let progress = request.progress
        let poller = Task {
            var last = -1.0
            while !Task.isCancelled {
                let fraction = progress.fractionCompleted
                if abs(fraction - last) > 0.001 {
                    last = fraction
                    onStage?(.installingModel(fraction))
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poller.cancel() }

        try await request.downloadAndInstall()
        Log.app.notice("Modèle \(identifier, privacy: .public) installé")
        await reserveLocale(locale)
    }

    /// Sans réservation, l'asset peut être purgé par le système et retéléchargé
    /// à la session suivante.
    private static func reserveLocale(_ locale: Locale) async {
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            Log.app.error("Réservation de \(locale.identifier(.bcp47), privacy: .public) impossible : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fusionne les deux pistes en un transcript Markdown chronologique.
    static func mergeToMarkdown(mic: [TranscriptSegment],
                                system: [TranscriptSegment],
                                date: Date) -> String {
        var labeled: [LabeledSegment] =
            mic.map { LabeledSegment(start: $0.start, speaker: .me, text: $0.text) }
            + system.map { LabeledSegment(start: $0.start, speaker: .other, text: $0.text) }
        labeled.sort { $0.start < $1.start }

        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short

        var out = "# Transcript — \(df.string(from: date))\n\n"
        if labeled.isEmpty {
            out += "_(aucune parole détectée)_\n"
            return out
        }
        for seg in labeled {
            out += "**[\(timecode(seg.start))] \(seg.speaker.rawValue) :** \(seg.text)\n\n"
        }
        return out
    }

    private static func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
