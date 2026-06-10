import SwiftUI

struct AccountRowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let account: IMAPAccount
    @Binding var isExpanded: Bool
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16)
                Text(account.label.isEmpty ? account.host : account.label)
                    .font(.headline)
                Spacer()
                if !isExpanded && appState.activeProgress.values.contains(where: { $0.accountID == account.id }) {
                    ProgressView().controlSize(.small)
                }
            }
            Text(account.username)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
            scheduleIndicator
                .padding(.leading, 22)
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
        .listRowInsets(EdgeInsets(top: 20, leading: -3, bottom: 6, trailing: 0))
        .listRowBackground(
            VStack(spacing: 0) {
                Color.clear.frame(height: 16)
                Rectangle().fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            }
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Modifier") { onEdit() }
            Button("Sauvegarder maintenant") {
                Task { await backupEngine.backupAccount(account) }
            }
            .disabled(appState.isRunningBackup)
            Divider()
            Button("Supprimer", role: .destructive) {
                appState.removeAccount(account)
            }
        }
    }

    private var scheduleIndicator: some View {
        Group {
            if let next = account.schedule.nextBackupDate, next > Date() {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text(next, format: .dateTime.day().month(.abbreviated).hour().minute())
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
