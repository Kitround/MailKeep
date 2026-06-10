import SwiftUI
import UniformTypeIdentifiers

struct RestoreView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @Environment(\.dismiss) var dismiss

    let account: IMAPAccount
    let folder: MailFolder
    @State private var selectedFile: URL? = nil
    @State private var isRestoring = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Restaurer des emails")
                .font(.title2.bold())
            Text("Sélectionnez un fichier .mbox à réinjecter dans « \(folder.displayName) ».")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let file = selectedFile {
                HStack {
                    Image(systemName: "doc.fill")
                    Text(file.lastPathComponent)
                    Spacer()
                    Button("Changer") { selectFile() }
                }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Button {
                    selectFile()
                } label: {
                    Label("Choisir un fichier .mbox…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Button("Annuler") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Restaurer") {
                    guard let file = selectedFile else { return }
                    isRestoring = true
                    Task {
                        await backupEngine.restoreFolder(from: file, to: folder, on: account)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFile == nil || isRestoring)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        if let mboxType = UTType(filenameExtension: "mbox") {
            panel.allowedContentTypes = [mboxType]
        }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            selectedFile = panel.url
        }
    }
}
