import SwiftUI

struct FolderRowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let account: IMAPAccount
    let folder: MailFolder

    var isSelected: Bool {
        appState.selectedFolderID == folder.id && appState.selectedAccountID == account.id
    }

    var isRunning: Bool {
        appState.activeProgress.values.contains {
            $0.accountID == account.id && $0.folderName == folder.name
        }
    }

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center) {
            Image(systemName: iconName)
                .frame(width: 16)
                .foregroundStyle(folder.isEnabled ? .primary : .tertiary)
            Text(folder.displayName)
                .foregroundStyle(folder.isEnabled ? .primary : .secondary)
            Spacer()
            if isRunning {
                ProgressView().controlSize(.mini)
            } else if !folder.isEnabled {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(
            Rectangle().fill(
                isSelected    ? Color.accentColor.opacity(0.2)
                : isHovered   ? Color.primary.opacity(0.06)
                : Color.clear
            )
        )
        .onHover { isHovered = $0 }
        .onTapGesture {
            appState.selectedAccountID = account.id
            appState.selectedFolderID = folder.id
        }
        .contextMenu {
            Button("Sauvegarder maintenant") {
                Task { await backupEngine.backupFolder(account: account, folder: folder) }
            }
            .disabled(appState.isRunningBackup || !folder.isEnabled)
        }
    }

    private var iconName: String {
        let lower = folder.name.lowercased()
        if lower == "inbox" { return "tray.fill" }
        if lower.contains("sent") { return "paperplane.fill" }
        if lower.contains("draft") { return "doc.fill" }
        if lower.contains("trash") || lower.contains("deleted") { return "trash.fill" }
        if lower.contains("junk") || lower.contains("spam") { return "exclamationmark.octagon.fill" }
        if lower.contains("archive") { return "archivebox.fill" }
        return "folder.fill"
    }
}
