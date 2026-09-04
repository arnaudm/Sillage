import Foundation

/// Métadonnées d'une session, écrites à la fin de la transcription.
/// Les WAV étant supprimés, c'est la seule trace de la durée réelle.
struct SessionMeta: Codable, Sendable {
    var duration: TimeInterval
    var systemRequested: Bool     // « Capturer le son système » était actif
    var systemTranscribed: Bool   // la piste système existait et a été transcrite
    var micSegments: Int
    var systemSegments: Int
}

/// État de la piste « son système » d'une session, tel qu'affiché dans la liste.
enum SystemTrackState: Sendable {
    case unknown            // session antérieure au meta.json
    case disabled           // capture non demandée
    case unavailable        // demandée mais aucune piste produite
    case empty              // transcrite, aucune parole détectée
    case transcribed(Int)

    var segments: Int {
        if case .transcribed(let count) = self { return count }
        return 0
    }
}

/// Un jour de transcripts, pour l'affichage groupé.
struct TranscriptDay: Identifiable, Sendable {
    let id: String          // clé du jour
    let header: String      // « Aujourd'hui », « Hier », « 28/08 »
    let items: [TranscriptItem]
}

/// Un transcript horodaté sur disque.
struct TranscriptItem: Identifiable, Sendable {
    let id: String          // chemin du dossier de session
    let dir: URL
    let date: Date?         // instant de départ, nil si le nom de dossier est illisible
    let displayDate: String
    let text: String
    var label: String
    let duration: TimeInterval?
    let durationIsEstimated: Bool   // déduite du dernier horodatage, pas mesurée
    let micSegments: Int
    let systemTrack: SystemTrackState
    let hasAudio: Bool      // WAV encore présents : session en cours, ou transcription échouée

    /// transcript.md est toujours écrit avec au moins un titre → un fichier
    /// absent (`false`) ne veut jamais dire « aucune parole détectée ».
    var hasText: Bool { !text.isEmpty }

    /// Transcript produit, mais aucune parole sur aucune des deux pistes.
    var isSilent: Bool { hasText && micSegments == 0 && systemTrack.segments == 0 }

    var hasCustomLabel: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Titre affiché hors contexte de jour (vue détail, titre de la copie,
    /// confirmation de suppression) : le label, sinon la date complète.
    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayDate : trimmed
    }

    /// Heure de départ seule. Identité d'une ligne à l'intérieur d'un groupe.
    var timeString: String {
        guard let date else { return displayDate }
        return TranscriptStore.timeString(from: date)
    }

    /// Jour et heure en une ligne, pour les listes non groupées (le panneau).
    var shortDateTimeString: String {
        guard let date else { return displayDate }
        return TranscriptStore.shortDateTimeString(from: date)
    }

    /// Le corps du transcript sans son titre H1 (redondant avec displayName).
    var bodyText: String {
        guard text.hasPrefix("# ") else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop { $0.hasPrefix("# ") || $0.isEmpty }
            .joined(separator: "\n")
    }

    var durationString: String? {
        guard let duration, duration >= 1 else { return nil }
        let s = Int(duration.rounded())
        let base = s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
        return durationIsEstimated ? "~\(base)" : base
    }
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
    /// `limit` évite de relire tous les transcripts pour n'en afficher que
    /// quelques-uns (le panneau de la barre de menus).
    static func list(limit: Int? = nil) -> [TranscriptItem] {
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
        let retained = limit.map { Array(sorted.prefix($0)) } ?? sorted

        return retained.map { dir in
            let name = dir.lastPathComponent
            let text = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
            let label = (try? String(contentsOf: dir.appendingPathComponent("label.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let meta = loadMeta(in: dir)

            // Sans meta.json (sessions antérieures), on retombe sur le transcript :
            // dernier horodatage pour la durée, présence des locuteurs pour les pistes.
            let duration = meta?.duration ?? lastTimecode(in: text)
            let micSegments = meta?.micSegments ?? count(of: .me, in: text)

            let date = parser.date(from: name)

            return TranscriptItem(id: dir.path,
                                  dir: dir,
                                  date: date,
                                  displayDate: date.map { display.string(from: $0) } ?? name,
                                  text: text,
                                  label: label,
                                  duration: duration,
                                  durationIsEstimated: meta == nil && duration != nil,
                                  micSegments: micSegments,
                                  systemTrack: systemTrack(meta: meta, text: text),
                                  hasAudio: hasAudio(in: dir))
        }
    }

    /// Découpe une liste déjà triée (plus récent en premier) en groupes de jour.
    /// Aucun retri : on coupe à chaque changement de journée rencontré.
    static func grouped(_ items: [TranscriptItem]) -> [TranscriptDay] {
        let calendar = Calendar.current
        var days: [TranscriptDay] = []
        var currentKey: String?
        var bucket: [TranscriptItem] = []

        func flush() {
            guard let key = currentKey, !bucket.isEmpty else { return }
            days.append(TranscriptDay(id: key,
                                      header: dayHeader(for: bucket[0]),
                                      items: bucket))
            bucket = []
        }

        for item in items {
            // Le nom de dossier est en UTC : c'est le calendrier local, appliqué
            // à l'instant absolu, qui décide du jour d'appartenance.
            let key = item.date.map { calendar.startOfDay(for: $0).description } ?? item.id
            if key != currentKey {
                flush()
                currentKey = key
            }
            bucket.append(item)
        }
        flush()
        return days
    }

    private static func dayHeader(for item: TranscriptItem) -> String {
        guard let date = item.date else { return item.displayDate }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Aujourd'hui"
        }
        if calendar.isDateInYesterday(date) {
            return "Hier"
        }
        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: Date())
        return (sameYear ? dayShort : dayFull).string(from: date)
    }

    /// Supprime toute la session (dossier + WAV éventuels + transcript + label + meta).
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

    // MARK: - Métadonnées de session

    static func saveMeta(_ meta: SessionMeta, in dir: URL) {
        let url = dir.appendingPathComponent("meta.json")
        do {
            try JSONEncoder().encode(meta).write(to: url, options: .atomic)
        } catch {
            Log.app.error("Échec écriture meta.json : \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadMeta(in dir: URL) -> SessionMeta? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionMeta.self, from: data)
    }

    private static func hasAudio(in dir: URL) -> Bool {
        let fm = FileManager.default
        return ["mic.wav", "system.wav"].contains {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    private static func systemTrack(meta: SessionMeta?, text: String) -> SystemTrackState {
        guard let meta else {
            let n = count(of: .other, in: text)
            return n > 0 ? .transcribed(n) : .unknown
        }
        if !meta.systemRequested {
            return .disabled
        }
        if !meta.systemTranscribed {
            return .unavailable
        }
        return meta.systemSegments > 0 ? .transcribed(meta.systemSegments) : .empty
    }

    // MARK: - Repli sur le contenu du transcript

    private static let timecodeRegex = #/\[(\d+):(\d{2})\]/#

    /// Dernier horodatage du transcript, en secondes — approximation de la durée.
    private static func lastTimecode(in text: String) -> TimeInterval? {
        var last: TimeInterval?
        for match in text.matches(of: timecodeRegex) {
            guard let minutes = Int(String(match.1)), let seconds = Int(String(match.2)) else { continue }
            last = TimeInterval(minutes * 60 + seconds)
        }
        return last
    }

    private static func count(of speaker: Speaker, in text: String) -> Int {
        text.components(separatedBy: "] \(speaker.rawValue) :").count - 1
    }

    // MARK: - Formatage de la date

    // Un format fixe se lit et s'écrit avec une locale figée : sur un calendrier
    // non grégorien, « yyyy » donnerait sinon l'année du calendrier de l'utilisateur.
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "dd/MM/yyyy HH'h'mm"
        return f
    }()

    // « 11h40 » plutôt que « 11:40 » : les deux-points restent réservés aux
    // durées (46:31) et aux horodatages du transcript.
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "HH'h'mm"
        return f
    }()

    private static let dayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "dd/MM"
        return f
    }()

    private static let dayFull: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "dd/MM/yyyy"
        return f
    }()

    private static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = "dd/MM HH'h'mm"
        return f
    }()

    static func timeString(from date: Date) -> String {
        time.string(from: date)
    }

    static func shortDateTimeString(from date: Date) -> String {
        shortDateTime.string(from: date)
    }
}
