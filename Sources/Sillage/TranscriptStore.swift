import Foundation

/// Un transcript horodaté sur disque.
struct TranscriptItem: Identifiable, Sendable {
    let id: String          // chemin du dossier de session
    let dir: URL
    let displayDate: String
    let text: String
    var label: String
    var hasText: Bool { !text.isEmpty }
}

/// Accès aux transcripts enregistrés dans
/// ~/Library/Application Support/Sillage/Recordings/<horodatage>/transcript.md
enum TranscriptStore {

    static func recordingsBase() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sillage/Recordings", isDirectory: true)
    }

    /// Liste les sessions, la plus récente en premier.
    static func list() -> [TranscriptItem] {
        let fm = FileManager.default
        let base = recordingsBase()
        guard let entries = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let dirs = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        // Les noms sont ISO8601 → l'ordre lexicographique décroissant = du plus récent au plus ancien.
        let sorted = dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }

        return sorted.map { dir in
            let name = dir.lastPathComponent
            let text = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
            let label = (try? String(contentsOf: dir.appendingPathComponent("label.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return TranscriptItem(id: dir.path,
                                  dir: dir,
                                  displayDate: prettyDate(from: name),
                                  text: text,
                                  label: label)
        }
    }

    /// Supprime toute la session (dossier + WAV éventuels + transcript + label).
    static func delete(_ item: TranscriptItem) throws {
        try FileManager.default.removeItem(at: item.dir)
    }

    /// Définit (ou efface, si vide) le label d'une session, persisté dans label.txt.
    static func setLabel(_ label: String, for item: TranscriptItem) {
        let url = item.dir.appendingPathComponent("label.txt")
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            do {
                try trimmed.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.app.error("Échec écriture label : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Formatage de la date

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private static func prettyDate(from dirName: String) -> String {
        if let date = parser.date(from: dirName) {
            return display.string(from: date)
        }
        return dirName
    }
}
