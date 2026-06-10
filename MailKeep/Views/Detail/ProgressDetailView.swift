import SwiftUI

struct ProgressDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine
    let progress: BackupProgress

    var body: some View {
        VStack(spacing: 20) {
            switch progress.phase {

            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text("Backup terminé")
                    .font(.title2.bold())

            case .stopped:
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
                Text("Arrêté")
                    .font(.title2.bold())
                Text("Les messages déjà téléchargés sont sauvegardés.\nLe prochain backup reprendra automatiquement.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .padding(.horizontal)
                if progress.total > 0 {
                    Text("\(progress.current) / \(progress.total) téléchargés")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.red)
                Text("Échec")
                    .font(.title2.bold())
                if let err = progress.errorMessage {
                    Text(err)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

            default:
                // Active phases
                ProgressView(value: progress.total > 0 ? progress.percentComplete : nil)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)

                Text(progress.phase.rawValue)
                    .font(.headline)

                if progress.total > 0 {
                    Text("\(progress.current) / \(progress.total) messages")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let uid = progress.currentUID {
                    Text("UID \(uid)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                // Stop button — only on download phases
                if progress.phase == .downloadingMessages {
                    Button {
                        backupEngine.requestStop(accountID: progress.accountID, folderName: progress.folderName)
                    } label: {
                        Label("Arrêter", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .help("Arrête le backup proprement. Les messages déjà téléchargés sont conservés et le prochain backup reprendra où il s'est arrêté.")
                }
            }

            Text("\(progress.accountLabel) — \(progress.folderName)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
