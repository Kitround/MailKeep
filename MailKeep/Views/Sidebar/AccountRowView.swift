import SwiftUI

struct AccountRowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let account: IMAPAccount
    @Binding var isExpanded: Bool
    let onEdit: () -> Void

    @State private var isHovered = false
    @State private var gearHovered = false
    @State private var showDeleteConfirm = false

    private var isBacking: Bool {
        appState.activeProgress.values.contains { $0.accountID == account.id }
    }

    var body: some View {
        HStack(spacing: 6) {
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

            // Per-account settings — vertically centered against the name + email lines.
            if !isExpanded && isBacking {
                ProgressView().controlSize(.small)
            }
            Button(action: onEdit) {
                SidebarIconLabel(systemName: "gearshape", isHovered: gearHovered)
            }
            .buttonStyle(.plain)
            .onHover { gearHovered = $0 }
            .help("Réglages du compte")
            .opacity(isHovered || gearHovered ? 1 : 0.5)
            .padding(.trailing, SidebarIcon.trailing - SidebarIcon.pad)
        }
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
                showDeleteConfirm = true
            }
            .disabled(isBacking)
        }
        // Removing an account drops its keychain password and its downloaded-UID state:
        // nothing comes back, and the next backup re-downloads the whole mailbox. Every
        // other irreversible action in the app asks first; this one went through on the
        // click.
        .confirmationDialog(
            "Supprimer le compte « \(account.label.isEmpty ? account.host : account.label) » ?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                appState.removeAccount(account)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le mot de passe enregistré dans le trousseau et le suivi des messages déjà téléchargés seront effacés. Les fichiers .mbox déjà sauvegardés restent sur le disque.")
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
