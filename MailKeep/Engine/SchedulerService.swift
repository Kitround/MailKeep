import Foundation

@MainActor
final class SchedulerService: ObservableObject {
    private var timer: Timer?
    private weak var appState: AppState?
    private weak var engine: BackupEngine?

    func start(appState: AppState, engine: BackupEngine) {
        self.appState = appState
        self.engine = engine
        // start() est appelé depuis le onAppear de la fenêtre : une seconde fenêtre
        // lançait un deuxième timer, donc deux backups planifiés simultanés.
        guard timer == nil else { return }

        // Check every minute if a scheduled backup is due
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkDueBackups()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        // Pas de vérification au démarrage — l'utilisateur relance manuellement
        // depuis l'historique si un backup précédent n'a pas pu se terminer.
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
