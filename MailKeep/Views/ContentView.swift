import SwiftUI
import AppKit

/// Pins the width of the account column with an Auto Layout constraint on the column
/// itself.
///
/// The column stays a split view column: it is what gives the window the
/// `sidebarTrackingSeparator` in its toolbar, and with it the position of the icons above
/// the sidebar and the title above the middle column. Taken out of the split, all of that
/// chrome goes with it.
///
/// The constraint sits on the column view, not on the `NSSplitViewItem`: the item's
/// thicknesses die with it whenever SwiftUI rebuilds its columns, while the constraint
/// lives as long as the column does. Nothing to reapply continuously, so nothing fighting
/// AppKit's layout pass — and a required constraint leaves the divider no slack, nor does
/// it leave any to geometry restored at launch.
private struct ColumnWidthLock: NSViewRepresentable {
    let width: CGFloat

    private static let identifier = "MailKeepSidebarWidth"

    final class Coordinator {
        var observer: NSObjectProtocol?
        var apply: (() -> Void)?
        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.apply = { [weak nsView] in
            guard let nsView else { return }
            Self.apply(width: width, from: nsView)
        }
        // When SwiftUI rebuilds its columns — which every history refresh mid-backup does
        // — the new column starts with no constraint, and `updateNSView` is not called
        // again because the width has not changed. So the constraint is re-attached after
        // each resize pass: deferred, to write nothing during AppKit's own pass, and a
        // no-op when the constraint is already in place.
        if coordinator.observer == nil {
            coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: nil, queue: .main
            ) { [weak coordinator] _ in
                DispatchQueue.main.async { coordinator?.apply?() }
            }
        }
        // Deferred: at call time the view is not in the split view hierarchy yet.
        DispatchQueue.main.async { coordinator.apply?() }
    }

    private static func apply(width: CGFloat, from nsView: NSView) {
        var candidate: NSView? = nsView
        while let view = candidate, !(view.superview is NSSplitView) {
            candidate = view.superview
        }
        guard let column = candidate, let split = column.superview as? NSSplitView else { return }

        // `>=` rather than `==`: the column can be widened at the divider, but never
        // squeezed under its content width — not by a drag, not by restored geometry.
        if let existing = column.constraints.first(where: { $0.identifier == identifier }) {
            if existing.constant != width { existing.constant = width }
        } else {
            let lock = column.widthAnchor.constraint(greaterThanOrEqualToConstant: width)
            lock.identifier = identifier
            lock.isActive = true
        }

        // Without this the column stays collapsible from the View menu.
        if let controller = split.delegate as? NSSplitViewController,
           let index = split.arrangedSubviews.firstIndex(of: column),
           controller.splitViewItems.indices.contains(index) {
            controller.splitViewItems[index].canCollapse = false
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// Width of the account column: that of its content, loader and icon included.
    private var sidebarWidth: CGFloat { SidebarMetrics.width(for: appState.accounts) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                // Starting width; from then on the lock below bounds the floor, and the
                // divider stays free to move right.
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: 700)
                .background(ColumnWidthLock(width: sidebarWidth))
                .toolbar(removing: .sidebarToggle)
        } content: {
            // Center panel: email list if mbox available, else backup history
            if let account = appState.selectedAccount,
               let folder = appState.selectedFolder,
               !appState.selectedMboxURLs.isEmpty {
                EmailListView(account: account, folder: folder,
                              mboxURLs: appState.selectedMboxURLs,
                              indexURL: appState.selectedIndexURL)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
            } else {
                BackupHistoryView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
            }
        } detail: {
            // Detail: email reader if selected, else folder/progress view
            if let email = appState.selectedEmail {
                EmailDetailView(email: email)
            } else {
                DetailView()
            }
        }
        .toolbar(removing: .sidebarToggle)
        .navigationTitle("MailKeep")
        .frame(minWidth: 900, minHeight: 600)
        // Reset selected email when folder changes
        .onChange(of: appState.selectedFolderID) { _, _ in
            appState.selectedEmail = nil
        }
        // Stops the sidebar being collapsed from a keyboard shortcut or the View menu
        .onChange(of: columnVisibility) { _, v in
            if v != .all { columnVisibility = .all }
        }
    }
}
