import SwiftUI

struct BackupRunRowView: View {
    let run: BackupRun
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var backupEngine: BackupEngine

    /// Progression en cours pour ce dossier précis
    private var activeProgress: BackupProgress? {
        appState.activeProgress.values.first {
            $0.accountID == run.accountID && $0.folderName == run.folderName
        }
    }

    private var isBacking: Bool { activeProgress != nil }

    /// Retrouve le compte et le dossier correspondant au run
    private var accountAndFolder: (IMAPAccount, MailFolder)? {
        guard let account = appState.accounts.first(where: { $0.id == run.accountID }),
              let folder  = account.folders.first(where: { $0.name == run.folderName })
        else { return nil }
        return (account, folder)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                // Ligne 1 : dossier + compte + date
                HStack(alignment: .firstTextBaseline) {
                    Text(run.folderName)
                        .font(.headline)
                    Text("–")
                        .foregroundStyle(.tertiary)
                    Text(run.accountLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(run.startedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                // Ligne 2 : stats + bouton reprendre
                HStack(spacing: 10) {
                    statsLine
                    Spacer(minLength: 0)
                    resumeButton
                }

                // Ligne 3 : erreur si présente
                if let error = run.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - Bouton Reprendre

    @ViewBuilder
    private var resumeButton: some View {
        if (run.status == .stopped || run.status == .failed),
           let (account, folder) = accountAndFolder {
            Button {
                Task { await backupEngine.backupFolder(account: account, folder: folder) }
            } label: {
                Label("Reprendre", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(isBacking)
        }
    }

    // MARK: - Stats line

    @ViewBuilder
    private var statsLine: some View {
        switch run.status {
        case .inProgress:
            if let progress = activeProgress {
                HStack(spacing: 10) {
                    Text(progress.phase.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if progress.total > 0 {
                        Label("\(progress.current) / \(progress.total)", systemImage: "arrow.down")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
            } else {
                Label("En cours…", systemImage: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .stopped:
            HStack(spacing: 10) {
                if run.messagesDownloaded > 0 {
                    Label("\(run.messagesDownloaded) téléchargés", systemImage: "arrow.down")
                        .font(.caption).foregroundStyle(.orange)
                }
                if run.messagesSkipped > 0 {
                    Label("\(run.messagesSkipped) existants", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Label("Arrêté", systemImage: "pause.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

        case .success:
            HStack(spacing: 10) {
                if run.messagesDownloaded > 0 {
                    Label("\(run.messagesDownloaded) nouveaux", systemImage: "arrow.down")
                        .font(.caption).foregroundStyle(.primary)
                } else {
                    Label("À jour", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                }
                if run.messagesSkipped > 0 {
                    Label("\(run.messagesSkipped) existants", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if run.bytesWritten > 0 {
                    Text(formatBytes(run.bytesWritten))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        case .failed:
            EmptyView()
        }
    }

    // MARK: - Icon

    private var statusIcon: some View {
        Group {
            switch run.status {
            case .inProgress:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                    .frame(width: 22, height: 22)
            case .stopped:
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                    .frame(width: 22, height: 22)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
                    .frame(width: 22, height: 22)
            }
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000
        if gb >= 1  { return String(format: "%.1f Go", gb) }
        if mb >= 1  { return String(format: "%.1f Mo", mb) }
        return String(format: "%.0f Ko", kb)
    }
}
