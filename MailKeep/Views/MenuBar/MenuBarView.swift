import SwiftUI

/// Contents of the menu bar companion: the quick actions, and nothing else.
///
/// Rendered in a panel (`.menuBarExtraStyle(.window)`), never in an `NSMenu` — and that is
/// the whole point of the choice. The first version was an AppKit menu that re-read
/// `activeProgress` during a backup: macOS menu updates are synchronous and re-entrant, so
/// every progress write called `menuNeedsUpdate`, which rendered, which dirtied the menu
/// again, until the stack blew. A SwiftUI panel has no menu graph to dirty.
///
/// It carries no status line: the one it had ended in a relative date that ticked over
/// every second, so the panel never sat still. Progress belongs in the window, which shows
/// it per folder and in the history.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var canBackup: Bool {
        !appState.isRunningBackup && !appState.accounts.isEmpty && appState.backupBaseURL != nil
    }

    var body: some View {
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
        .frame(width: 220)
    }
}

// MARK: - Metrics

/// Shared measurements for the panel. They exist for one reason: every icon has to land on
/// the same vertical at the same size, which no value written row by row ever guaranteed.
private enum MenuBarMetrics {
    /// Padding around the block of actions.
    static let rowPadding: CGFloat = 6
    /// Inner padding of an action row.
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
                // No colour set: the glyph follows the row's `foregroundStyle`, which drops
                // to tertiary when the action is disabled.
                Image(systemName: systemImage)
                    .font(.system(size: MenuBarMetrics.iconSize))
                    .frame(width: MenuBarMetrics.iconBox, height: MenuBarMetrics.iconBox)
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
