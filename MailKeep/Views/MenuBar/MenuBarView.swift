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
                // Même retrait que le contenu d'une ligne d'action, pour que le glyphe
                // d'état tombe sur la verticale des glyphes des boutons.
                .padding(.horizontal, MenuBarMetrics.rowPadding + MenuBarMetrics.contentInset)
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
            .padding(MenuBarMetrics.rowPadding)
        }
        .frame(width: 260)
    }

    // MARK: - État

    @ViewBuilder
    private var status: some View {
        if appState.isRunningBackup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(appState.activeProgress.values)) { progress in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(progress.folderName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        // Barre déterminée quand le total est connu, indéterminée pendant
                        // la connexion et la récupération des UIDs. L'avancement se lit
                        // sur la barre — le compteur chiffré doublait l'information.
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
            HStack(spacing: MenuBarMetrics.iconGap) {
                MenuBarIcon(systemName: lastRunSymbol.name, color: lastRunSymbol.color)
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
            // `.relative` rend déjà une durée écoulée (« 2 j et 23 h ») : la faire suivre
            // de « plus tôt » donnait « 2 j et 23 h plus tôt ».
            (Text("Dernier backup il y a ") + Text(finished, style: .relative))
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

// MARK: - Métriques

/// Mesures partagées du panneau. Elles existent pour une seule raison : toutes les icônes
/// doivent tomber sur la même verticale et faire la même taille, ce qu'aucune valeur posée
/// ligne par ligne ne garantissait.
private enum MenuBarMetrics {
    /// Marge du bloc d'actions.
    static let rowPadding: CGFloat = 6
    /// Marge interne d'une ligne d'action. Additionnée à `rowPadding`, elle donne le retrait
    /// du glyphe — le même que celui du bloc d'état, qui n'est pas dans une ligne.
    static let contentInset: CGFloat = 8
    /// Écart entre le glyphe et son libellé.
    static let iconGap: CGFloat = 8
    /// Corps du glyphe.
    static let iconSize: CGFloat = 13
    /// Boîte carrée commune. Les symboles SF n'ont pas la même largeur intrinsèque —
    /// « macwindow » fait 18 pt de large, « power » 15 — donc sans cadre imposé leurs
    /// centres ne tombent pas au même endroit et les libellés partent en escalier.
    static let iconBox: CGFloat = 18
}

/// Glyphe du panneau : même corps et même boîte pour tous, d'où l'alignement.
///
/// Sans `color`, aucune teinte n'est posée et le glyphe hérite de celle de son parent —
/// c'est ce qui fait passer l'icône d'une action désactivée en tertiaire avec son libellé.
private struct MenuBarIcon: View {
    let systemName: String
    var color: Color? = nil

    var body: some View {
        let glyph = Image(systemName: systemName)
            .font(.system(size: MenuBarMetrics.iconSize))
        Group {
            if let color { glyph.foregroundStyle(color) } else { glyph }
        }
        .frame(width: MenuBarMetrics.iconBox, height: MenuBarMetrics.iconBox)
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
            HStack(spacing: MenuBarMetrics.iconGap) {
                // Pas de couleur imposée : le glyphe suit le `foregroundStyle` de la ligne,
                // qui passe en tertiaire quand l'action est désactivée.
                MenuBarIcon(systemName: systemImage, color: nil)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MenuBarMetrics.contentInset)
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
