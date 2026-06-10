import SwiftUI
import AppKit

struct EmailDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let email: EmailMessage
    @State private var showRestoreSheet = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            if !email.attachments.isEmpty {
                Divider()
                attachmentsSection
            }
            Divider()
            bodySection
        }
        .navigationTitle(email.subject)
        .toolbar {
            ToolbarItem {
                Button {
                    exportEML()
                } label: {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                }
                .help("Exporter ce message en fichier .eml (pièces jointes incluses)")
            }
            ToolbarItem {
                Button {
                    showRestoreSheet = true
                } label: {
                    Label("Restaurer ce message", systemImage: "arrow.up.circle")
                }
                .help("Réinjecter ce message dans un dossier IMAP")
                .disabled(appState.accounts.isEmpty)
            }
        }
        .sheet(isPresented: $showRestoreSheet) {
            RestoreMessageView(email: email)
                .environmentObject(appState)
                .environmentObject(backupEngine)
        }
    }

    // MARK: - Export

    private func exportEML() {
        // Récupère les données brutes du message (RFC 822 complet, pièces jointes incluses)
        let data: Data?
        if let url = email.mboxFileURL, email.mboxLength > 0 {
            data = try? MboxStore.readMessage(at: email.mboxOffset, length: email.mboxLength, from: url)
        } else {
            data = email.rawData
        }
        guard let emlData = data, !emlData.isEmpty else { return }

        let safeName = email.subject
            .components(separatedBy: CharacterSet(charactersIn: "/\\?%*:|\"<>"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        let defaultName = safeName.isEmpty ? "email" : safeName

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).eml"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.init(filenameExtension: "eml") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? emlData.write(to: url)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(email.subject)
                .font(.title3.bold())
                .textSelection(.enabled)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                headerRow(label: "De", value: email.from)
                if !email.to.isEmpty {
                    headerRow(label: "À", value: email.to)
                }
                if !email.cc.isEmpty {
                    headerRow(label: "Cc", value: email.cc)
                }
                if let date = email.date {
                    GridRow {
                        Text("Date")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .gridColumnAlignment(.trailing)
                        Text(date.formatted(date: .long, time: .shortened))
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
    }

    private func headerRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(email.attachments) { att in
                    AttachmentChip(attachment: att)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.background)
    }

    // MARK: - Body

    private var bodySection: some View {
        Group {
            if let html = email.bodyHTML, !html.isEmpty {
                WebView(html: html)
            } else if let text = email.bodyText, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Aucun contenu",
                    systemImage: "doc",
                    description: Text("Le corps de cet email est vide ou dans un format non supporté.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Attachment chip

struct AttachmentChip: View {
    let attachment: EmailAttachment
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.sfSymbol)
                .font(.system(size: 13))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(attachment.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                saveAttachment(attachment)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Enregistrer \(attachment.filename)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.accentColor.opacity(0.1) : Color(.windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        )
        .onHover { isHovered = $0 }
        .onTapGesture { saveAttachment(attachment) }
    }

    private func saveAttachment(_ att: EmailAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = att.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? att.data.write(to: url)
    }
}
