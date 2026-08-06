import SwiftUI

struct AccountRowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let account: IMAPAccount
    @Binding var isExpanded: Bool
    let onEdit: () -> Void

    @State private var isHovered = false
    @State private var gearHovered = false

    private var isBacking: Bool {
        appState.activeProgress.values.contains { $0.accountID == account.id }
    }

    var body: some View {
        // Même écart que sur les lignes de dossier, pour que loaders et icônes d'action
        // tombent exactement sur les mêmes verticales d'une ligne à l'autre.
        HStack(spacing: SidebarIcon.gap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16)
                    Text(account.label.isEmpty ? account.host : account.label)
                        .font(.headline)
                        // Jamais de « … » : le texte garde sa largeur, quoi qu'il arrive à la colonne.
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                }
                Text(account.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 22)
                scheduleIndicator
                    .padding(.leading, 22)
            }
            // Même raison que sur les lignes de dossier : avec des textes en `fixedSize`,
            // sans largeur imposée la ligne se réduit à son contenu et la roue crantée
            // vient se coller au texte au lieu de rester sur sa colonne.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            SidebarRowTrailing {
                if !isExpanded && isBacking {
                    ProgressView().controlSize(.small)
                } else {
                    // Vue concrète et non un `EmptyView`, qui ne réserverait aucune place.
                    Color.clear
                }
            } action: {
                Button(action: onEdit) {
                    SidebarIconLabel(systemName: "gearshape", isHovered: gearHovered)
                }
                .buttonStyle(.plain)
                .onHover { gearHovered = $0 }
                .help("Réglages du compte")
                .opacity(isHovered || gearHovered ? 1 : 0.5)
            }
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
