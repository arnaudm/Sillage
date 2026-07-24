import SwiftUI
import AppKit

/// Fenêtre listant les derniers transcripts horodatés. Pour chacun : copier le
/// texte dans le presse-papiers, ou supprimer la session (avec confirmation).
struct TranscriptsView: View {
    @State private var items: [TranscriptItem] = []
    @State private var pendingDelete: TranscriptItem?
    @State private var justCopiedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcripts").font(.title2).bold()
                Spacer()
                Button {
                    openFolder()
                } label: {
                    Label("Ouvrir dans le Finder", systemImage: "folder")
                }
                Button {
                    reload()
                } label: {
                    Label("Rafraîchir", systemImage: "arrow.clockwise")
                }
            }
            .padding()

            Divider()

            if items.isEmpty {
                Spacer()
                Text("Aucun transcript pour le moment.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(items) { item in
                        TranscriptRow(
                            item: item,
                            justCopied: justCopiedID == item.id,
                            onCopy: { copy(item, label: $0) },
                            onDelete: { pendingDelete = item },
                            onRename: { TranscriptStore.setLabel($0, for: item) }
                        )
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 300)
        .onAppear(perform: reload)
        .confirmationDialog(
            "Supprimer ce transcript ?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Supprimer", role: .destructive) { delete(item) }
            Button("Annuler", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("La session « \(item.displayDate) » et ses fichiers audio éventuels seront supprimés définitivement.")
        }
    }

    private func reload() {
        items = TranscriptStore.list()
    }

    private func openFolder() {
        let url = TranscriptStore.recordingsBase()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func copy(_ item: TranscriptItem, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmed.isEmpty ? item.text : "# \(trimmed)\n\n\(item.text)"
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
        reload()
    }
}

/// Une ligne : champ label éditable (sauvegardé à la volée) + date + actions.
private struct TranscriptRow: View {
    let item: TranscriptItem
    let justCopied: Bool
    let onCopy: (String) -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void

    @State private var label: String

    init(item: TranscriptItem,
         justCopied: Bool,
         onCopy: @escaping (String) -> Void,
         onDelete: @escaping () -> Void,
         onRename: @escaping (String) -> Void) {
        self.item = item
        self.justCopied = justCopied
        self.onCopy = onCopy
        self.onDelete = onDelete
        self.onRename = onRename
        _label = State(initialValue: item.label)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Label (optionnel)", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onChange(of: label) { _, newValue in onRename(newValue) }
                HStack(spacing: 4) {
                    Text(item.displayDate)
                    if !item.hasText {
                        Text("· transcription en cours ou vide")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onCopy(label)
            } label: {
                Label(justCopied ? "Copié ✓" : "Copier", systemImage: "doc.on.doc")
            }
            .disabled(!item.hasText)

            Button(role: .destructive, action: onDelete) {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }
}
