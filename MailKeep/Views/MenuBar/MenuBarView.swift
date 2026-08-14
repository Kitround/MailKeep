import SwiftUI

/// Contenu du compagnon de la barre de menus : état du backup en cours et actions rapides.
///
/// Rendu dans un panneau (`.menuBarExtraStyle(.window)`), jamais dans un `NSMenu` — et
/// c'est la raison d'être de ce choix. La version précédente était un menu AppKit qui
/// relisait `activeProgress` pendant un backup : les mises à jour de menu de macOS sont
/// synchrones et ré-entrantes, donc chaque écriture de progression rappelait
/// `menuNeedsUpdate`, qui rendait, qui salissait le menu à nouveau, jusqu'au débordement
/// de pile. Un panneau SwiftUI n'a pas de graphe de menu à salir : il peut observer l'état
/// aussi souvent qu'il change.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var canBackup: Bool {
        !appState.isRunningBackup && !appState.accounts.isEmpty && appState.backupBaseURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 1) {
                MenuBarButton("Tout sauvegarder", systemImage: "arrow.down.circle", enabled: canBackup) {
                    dismiss()
                    Task { await backupEngine.backupAll() }
                }
                MenuBarButton("Ouvrir MailKeep", systemImage: "macwindow") {
                    dismiss()
                    // openWindow recrée la fenêtre si elle a été fermée —
                    // NSApp.windows.first ne marchait plus dans ce cas.
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }

                Divider().padding(.vertical, 4)

                MenuBarButton("Quitter MailKeep", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }
            .padding(6)
        }
        .frame(width: 260)
    }

    // MARK: - État

    @ViewBuilder
    private var status: some View {
        if appState.isRunningBackup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(appState.activeProgress.values)) { progress in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(progress.folderName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if progress.total > 0 {
                                Text("\(progress.current)/\(progress.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // Barre déterminée quand le total est connu, indéterminée pendant
                        // la connexion et la récupération des UIDs.
                        if progress.total > 0 {
                            ProgressView(value: progress.percentComplete)
                                .controlSize(.small)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(progress.phase.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: lastRunSymbol.name)
                    .foregroundStyle(lastRunSymbol.color)
                    .font(.caption)
                lastBackupLabel
                Spacer(minLength: 0)
            }
        }
    }

    private var lastRunSymbol: (name: String, color: Color) {
        switch appState.backupRuns.last?.status {
        case .failed:  return ("exclamationmark.triangle.fill", .orange)
        case .stopped: return ("pause.circle.fill", .orange)
        case .success: return ("checkmark.circle.fill", .green)
        default:       return ("clock", .secondary)
        }
    }

    @ViewBuilder
    private var lastBackupLabel: some View {
        if let last = appState.backupRuns.last, let finished = last.finishedAt {
            (Text("Dernier backup ") + Text(finished, style: .relative) + Text(" plus tôt"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("Aucun backup effectué")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Ligne d'action

/// Ligne cliquable d'un panneau de barre de menus : surlignage au survol, comme un item de
/// menu. Reprend le fond de survol des lignes de la sidebar, pour que l'app garde un seul
/// vocabulaire visuel.
private struct MenuBarButton: View {
    let title: String
    let systemImage: String
    var enabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    init(_ title: String, systemImage: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered && enabled ? Color.primary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .onHover { isHovered = $0 }
    }
}
