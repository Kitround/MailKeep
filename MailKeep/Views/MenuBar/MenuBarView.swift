import SwiftUI

/// Contents of the menu bar companion: current backup state plus the quick actions.
///
/// Rendered in a panel (`.menuBarExtraStyle(.window)`), never in an `NSMenu` — and that is
/// the whole point of the choice. The previous version was an AppKit menu that re-read
/// `activeProgress` during a backup: macOS menu updates are synchronous and re-entrant, so
/// every progress write called `menuNeedsUpdate`, which rendered, which dirtied the menu
/// again, until the stack blew. A SwiftUI panel has no menu graph to dirty, so it can watch
/// state as often as it changes.
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
                // Same inset as the contents of an action row, so the status glyph lands on
                // the same vertical as the button glyphs.
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
                    // openWindow recreates the window when it has been closed —
                    // NSApp.windows.first no longer worked in that case.
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

    // MARK: - State

    @ViewBuilder
    private var status: some View {
        if appState.isRunningBackup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(appState.activeProgress.values)) { progress in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(progress.folderName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        // Determinate once the total is known, indeterminate while
                        // connecting and fetching UIDs. The bar already carries how far
                        // along the folder is — a numeric counter said it twice.
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
            // `.relative` already renders elapsed time ("2 j et 23 h"), so following it
            // with "plus tôt" read as "2 j et 23 h plus tôt".
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

// MARK: - Metrics

/// Shared measurements for the panel. They exist for one reason: every icon has to land on
/// the same vertical at the same size, which no value written row by row ever guaranteed.
private enum MenuBarMetrics {
    /// Padding around the block of actions.
    static let rowPadding: CGFloat = 6
    /// Inner padding of an action row. Added to `rowPadding` it gives the glyph inset —
    /// the same one the status block uses, which is not inside a row.
    static let contentInset: CGFloat = 8
    /// Gap between a glyph and its label.
    static let iconGap: CGFloat = 8
    /// Glyph point size.
    static let iconSize: CGFloat = 13
    /// Shared square box. SF Symbols do not share an intrinsic width — "macwindow" is 18pt
    /// wide, "power" 15 — so without an imposed frame their centres land in different
    /// places and the labels step sideways.
    static let iconBox: CGFloat = 18
}

/// A panel glyph: one point size and one box for all of them, which is what aligns them.
///
/// With no `color`, no tint is applied and the glyph inherits its parent's — that is what
/// greys out a disabled action's icon along with its label.
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

// MARK: - Action row

/// A clickable row in a menu bar panel: hover highlight, like a menu item. Reuses the
/// sidebar rows' hover fill so the app keeps a single visual vocabulary.
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
                // No colour passed: the glyph follows the row's `foregroundStyle`, which
                // drops to tertiary when the action is disabled.
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
