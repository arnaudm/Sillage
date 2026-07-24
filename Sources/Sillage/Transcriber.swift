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

/// Transcription on-device via SpeechAnalyzer/SpeechTranscriber (macOS 26).
enum Transcriber {

    /// Transcrit un fichier audio complet et renvoie ses segments datés.
    static func transcribe(fileURL: URL, locale: Locale) async throws -> [TranscriptSegment] {
        // Résoudre une locale réellement supportée (ex. fr-FR).
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)

        // Télécharger/installer le modèle de langue si nécessaire (à la demande).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.app.notice("Installation du modèle de langue \(resolved.identifier(.bcp47), privacy: .public)…")
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: fileURL)

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
            }
            return segments
        }

        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return try await collector.value
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
