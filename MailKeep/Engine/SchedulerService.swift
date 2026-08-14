import Foundation

@MainActor
final class SchedulerService: ObservableObject {
    private var timer: Timer?
    private weak var appState: AppState?
    private weak var engine: BackupEngine?

    func start(appState: AppState, engine: BackupEngine) {
        self.appState = appState
        self.engine = engine
        // start() is called from the window's onAppear: a second window started a second
        // timer, hence two scheduled backups running at once.
        guard timer == nil else { return }

        // Check every minute if a scheduled backup is due
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkDueBackups()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        // No check at startup — the user restarts manually from the history if an earlier
        // backup could not finish.
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkDueBackups() async {
        guard let state = appState, let eng = engine else { return }
        guard !state.isRunningBackup else { return }

        for account in state.accounts where account.isEnabled && account.schedule.isDue {
            await eng.backupAccount(account)
        }
    }
}
