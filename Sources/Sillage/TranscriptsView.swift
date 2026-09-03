import SwiftUI
import AppKit

/// Fenêtre des transcripts : liste des sessions, puis vue détail (même fenêtre,
/// avec retour). Pour chaque session : renommer, copier, supprimer.
/// Ce que le panneau de la barre de menus demande à la fenêtre d'afficher.
/// Partagé entre les deux scènes, car la fenêtre peut ne pas encore exister
/// au moment du clic.
enum TranscriptRequest: Equatable {
    case list
    case detail(String)
}

@MainActor
final class TranscriptSelection: ObservableObject {
    @Published var request: TranscriptRequest?
}

/// État réel d'une session. Chaque cas a un sens unique — c'est ce qui permet
/// d'afficher un message affirmatif plutôt qu'une alternative.
enum SessionStatus {
    case ready          // transcript exploitable
    case silent         // transcript produit, aucune parole
    case recording                   // enregistrement en cours
    case transcribing(Double?)       // transcription en cours, avancement si connu
    case interrupted    // pas de transcript, mais l'audio est conservé
    case empty          // ni transcript ni audio
}

struct TranscriptsView: View {
    @EnvironmentObject private var controller: RecordingController
    @EnvironmentObject private var selection: TranscriptSelection
    @State private var items: [TranscriptItem] = []
    @State private var pendingDelete: TranscriptItem?
    @State private var justCopiedID: String?
    @State private var selectedID: String?

    /// Relu depuis `items` à chaque rendu → reste à jour après renommage/rechargement.
    private var selected: TranscriptItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    private func status(of item: TranscriptItem) -> SessionStatus {
        if let activity = controller.activity, activity.dirName == item.dir.lastPathComponent {
            return activity.phase == .recording
                ? .recording
                : .transcribing(controller.transcription?.overall)
        }
        if item.hasText {
            return item.isSilent ? .silent : .ready
        }
        return item.hasAudio ? .interrupted : .empty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = selected {
                detailView(item)
            } else {
                listView
            }
        }
        .frame(minWidth: 520, minHeight: 340)
        .onAppear {
            reload()
            consumeRequest()
        }
        .onChange(of: selection.request) { _, _ in consumeRequest() }
        .onChange(of: controller.activity) { _, _ in reload() }
        .confirmationDialog(
            "Supprimer cet enregistrement ?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Supprimer", role: .destructive) { delete(item) }
            Button("Annuler", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("L'enregistrement « \(item.displayName) » et ses fichiers audio éventuels seront supprimés définitivement.")
        }
    }

    // MARK: - Liste

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                if controller.isRecording {
                    HStack(spacing: 5) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.red)
                        Text(controller.elapsedString).monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                RecordButton()
                Button {
                    openFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Ouvrir dans le Finder")
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Relire le dossier des transcripts")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if items.isEmpty {
                Spacer()
                Text("Aucun transcript pour le moment.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // ScrollView plutôt que List : les séparateurs d'une List sont
                // alignés sur le contenu et s'arrêtent avant les boutons.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(TranscriptStore.grouped(items).enumerated()),
                                id: \.element.id) { dayIndex, day in
                            if dayIndex > 0 {
                                Divider()
                            }
                            DayHeader(title: day.header)
                            ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    Divider()
                                }
                                TranscriptRow(
                                    item: item,
                                    status: status(of: item),
                                    justCopied: justCopiedID == item.id,
                                    onOpen: { selectedID = item.id },
                                    onCopy: { copy(item) },
                                    onDelete: { pendingDelete = item }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Détail

    private func detailView(_ item: TranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    selectedID = nil
                } label: {
                    Label("Transcripts", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    copy(item)
                } label: {
                    Label(justCopiedID == item.id ? "Copié ✓" : "Copier", systemImage: "doc.on.doc")
                }
                .disabled(!item.hasText)

                Button(role: .destructive) {
                    pendingDelete = item
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                TextField(item.displayDate, text: labelBinding(for: item))
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                MetaLine(item: item, status: status(of: item), showsDate: true)
                if item.hasText {
                    TrackSummary(item: item)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Divider()

            if item.hasText {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(renderedLines(of: item).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
            } else {
                Spacer()
                placeholder(for: status(of: item), item: item)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }

    /// Affiché quand il n'y a pas encore de transcript à montrer.
    @ViewBuilder
    private func placeholder(for status: SessionStatus, item: TranscriptItem) -> some View {
        VStack(spacing: 6) {
            switch status {
            case .recording:
                Text("Enregistrement en cours…").font(.headline)
                Text("Le transcript sera généré à l'arrêt de l'enregistrement.")
                    .foregroundStyle(.secondary)
            case .transcribing:
                Text("Transcription en cours…").font(.headline)
                TranscriptionProgressView(progress: controller.transcription)
                Button("Annuler la transcription") {
                    controller.cancelTranscription()
                }
                .padding(.top, 4)
            case .interrupted:
                Text("La transcription ne s'est pas terminée.").font(.headline)
                Text("L'audio est conservé sur le disque : rien n'est perdu.")
                    .foregroundStyle(.secondary)
                if let error = controller.lastTranscriptionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Button {
                    controller.retryTranscription(at: item.dir)
                } label: {
                    Label("Relancer la transcription", systemImage: "arrow.clockwise")
                }
                .disabled(controller.activity != nil)
                .padding(.top, 4)
            default:
                Text("Cet enregistrement n'a produit aucun transcript.").font(.headline)
                Text("Son audio n'est plus présent.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Le transcript ligne à ligne, gras Markdown rendu (`**[00:12] Moi :**`).
    private func renderedLines(of item: TranscriptItem) -> [AttributedString] {
        item.bodyText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { (try? AttributedString(markdown: $0)) ?? AttributedString($0) }
    }

    /// Écrit le label à la volée. Pas de trim sur la valeur en mémoire, sinon
    /// impossible de taper une espace (elle serait rognée à chaque frappe).
    private func labelBinding(for item: TranscriptItem) -> Binding<String> {
        Binding(
            get: { items.first { $0.id == item.id }?.label ?? item.label },
            set: { newValue in
                TranscriptStore.setLabel(newValue, for: item)
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].label = newValue
                }
            }
        )
    }

    // MARK: - Actions

    /// Applique la demande venue du panneau, puis la vide.
    private func consumeRequest() {
        guard let request = selection.request else { return }
        switch request {
        case .list:
            selectedID = nil
        case .detail(let id):
            if items.contains(where: { $0.id == id }) {
                selectedID = id
            }
        }
        selection.request = nil
    }

    private func reload() {
        items = TranscriptStore.list()
        if let selectedID, !items.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    private func openFolder() {
        let url = TranscriptStore.recordingsBase()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func copy(_ item: TranscriptItem) {
        let content = "# \(item.displayName)\n\n\(item.bodyText)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        justCopiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if justCopiedID == item.id { justCopiedID = nil }
        }
    }

    private func delete(_ item: TranscriptItem) {
        do {
            try TranscriptStore.delete(item)
            Log.app.notice("Transcript supprimé : \(item.dir.path, privacy: .public)")
        } catch {
            Log.app.error("Échec suppression : \(error.localizedDescription, privacy: .public)")
        }
        pendingDelete = nil
        if selectedID == item.id {
            selectedID = nil
        }
        reload()
    }
}

/// Une ligne de la liste : titre cliquable (label ou date) + métadonnées + actions.
private struct TranscriptRow: View {
    let item: TranscriptItem
    let status: SessionStatus
    let justCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    // Taille et couleur constantes : c'est ce qui fait tenir la
                    // colonne d'heures, quelle que soit la présence d'un libellé.
                    Text(item.timeString)
                        .font(.body)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .leading)

                    if item.hasCustomLabel {
                        Text(item.displayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 12)
                    MetaLine(item: item, status: status)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Voir le transcript")

            RowIconButton(systemImage: justCopied ? "checkmark" : "doc.on.doc",
                          help: "Copier le transcript",
                          action: onCopy)
                .disabled(!item.hasText)

            RowIconButton(systemImage: "trash",
                          help: "Supprimer l'enregistrement",
                          destructive: true,
                          action: onDelete)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .onHover { hovering = $0 }
    }
}

/// Avancement d'une transcription : barre, pourcentage et restant estimé.
/// `TimelineView` fournit le battement d'une seconde qui rafraîchit
/// l'estimation entre deux segments.
private struct TranscriptionProgressView: View {
    let progress: TranscriptionProgress?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                if let progress {
                    if let overall = progress.overall {
                        ProgressView(value: overall)
                            .frame(width: 260)
                        Text(headline(progress, overall: overall))
                            .font(.callout)
                            .monospacedDigit()
                        if let remaining = progress.remaining(now: context.date) {
                            Text("Environ \(Self.humanDuration(remaining)) restantes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if let modelFraction = progress.modelFraction, modelFraction > 0 {
                            ProgressView(value: modelFraction)
                                .frame(width: 260)
                            Text("Installation du modèle de langue… \(Int(modelFraction * 100)) %")
                                .font(.callout)
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installation du modèle de langue (première utilisation)…")
                                .font(.callout)
                        }
                        // Le temps écoulé prouve que l'app vit, même si le
                        // téléchargement, lui, n'avance pas.
                        Text("Depuis \(Self.humanDuration(context.date.timeIntervalSince(progress.startedAt))) · téléchargement géré par macOS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private func headline(_ progress: TranscriptionProgress, overall: Double) -> String {
        let percent = "\(Int(overall * 100)) %"
        guard progress.trackCount > 1 else {
            return percent
        }
        return "\(percent) · piste \(progress.trackLabel) (\(progress.trackIndex + 1)/\(progress.trackCount))"
    }

    static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(max(total, 1)) s"
        }
        let minutes = total / 60
        let rest = total % 60
        if minutes >= 10 || rest == 0 {
            return "\(minutes) min"
        }
        return "\(minutes) min \(rest) s"
    }
}

/// Bouton icône d'une ligne, avec son propre survol — plus marqué que celui de
/// la ligne, sans quoi rien n'indique que l'icône est cliquable.
/// Partagé avec le panneau de la barre de menus.
struct RowIconButton: View {
    let systemImage: String
    let help: String
    var destructive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var active: Bool { hovering && isEnabled }

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(active && destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .frame(width: 24, height: 22)
                .background(background, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        guard active else { return .clear }
        return destructive ? Color.red.opacity(0.15) : Color.primary.opacity(0.14)
    }
}

/// Bandeau de jour séparant les groupes de la liste.
private struct DayHeader: View {
    let title: String

    var body: some View {
        // Même corps que les lignes : l'en-tête se distingue par la graisse, la
        // couleur et le bandeau, pas en étant plus petit que son contenu.
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))
    }
}

/// Durée et état d'un transcript. Dans la liste, la date est portée par
/// l'en-tête de jour et l'heure par la ligne : `showsDate` reste donc à false.
/// La vue détail, elle, n'a pas de contexte de jour et l'affiche.
private struct MetaLine: View {
    let item: TranscriptItem
    let status: SessionStatus
    var showsDate = false

    var body: some View {
        HStack(spacing: 10) {
            if showsDate && item.hasCustomLabel {
                Text(item.displayDate)
            }

            if let duration = item.durationString {
                Label(duration, systemImage: "clock")
                    .monospacedDigit()
                    .help(item.durationIsEstimated
                          ? "Durée estimée d'après le dernier horodatage du transcript"
                          : "Durée de l'enregistrement")
            }

            statusNote
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusNote: some View {
        switch status {
        case .ready:
            EmptyView()
        case .silent:
            Text("aucune parole détectée")
        case .recording:
            Text("enregistrement en cours…")
        case .transcribing(let fraction):
            if let fraction {
                Text("transcription \(Int(fraction * 100)) %").monospacedDigit()
            } else {
                Text("transcription en cours…")
            }
        case .interrupted:
            Text("transcription inachevée, audio conservé").foregroundStyle(.orange)
        case .empty:
            Text("aucun transcript").foregroundStyle(.orange)
        }
    }

}

/// Détail des deux pistes, en clair. Réservé à la vue détail : dans la liste,
/// les pictogrammes étaient plus énigmatiques qu'utiles.
private struct TrackSummary: View {
    let item: TranscriptItem

    var body: some View {
        HStack(spacing: 14) {
            Text("Micro : \(micSummary)")
            Text("Son système : \(systemSummary)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var micSummary: String {
        item.micSegments > 0 ? "\(item.micSegments) segments" : "aucune parole détectée"
    }

    private var systemSummary: String {
        switch item.systemTrack {
        case .transcribed(let count):
            return "\(count) segments"
        case .empty:
            return "aucune parole détectée"
        case .unavailable:
            return "capture indisponible"
        case .disabled:
            return "capture désactivée"
        case .unknown:
            return "état inconnu"
        }
    }
}
