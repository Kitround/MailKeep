import Foundation

struct BackupRun: Identifiable, Codable {
    var id: UUID = UUID()
    var accountID: UUID
    var accountLabel: String
    var folderName: String
    var startedAt: Date
    var finishedAt: Date? = nil
    var messagesDownloaded: Int = 0
    var messagesSkipped: Int = 0
    var bytesWritten: Int64 = 0
    var errorMessage: String? = nil
    var wasStopped: Bool = false

    enum Status { case inProgress, success, stopped, failed }
    var status: Status {
        guard finishedAt != nil else { return .inProgress }
        if wasStopped { return .stopped }
        if errorMessage != nil { return .failed }
        return .success
    }

    var duration: TimeInterval? {
        guard let end = finishedAt else { return nil }
        return end.timeIntervalSince(startedAt)
    }
}

struct BackupProgress: Identifiable {
    var id: UUID = UUID()
    var accountID: UUID
    var accountLabel: String
    var folderName: String
    var phase: Phase = .connecting
    var current: Int = 0
    var total: Int = 0
    var currentUID: UInt32? = nil
    var errorMessage: String? = nil

    enum Phase: String {
        case connecting = "Connexion…"
        case authenticating = "Authentification…"
        case selectingFolder = "Sélection du dossier…"
        case fetchingUIDList = "Récupération des UIDs…"
        case downloadingMessages = "Téléchargement des messages…"
        case writingMbox = "Écriture mbox…"
        case importing = "Importation en cours…"
        case stopped = "Arrêté"
        case done = "Terminé"
        case failed = "Échec"
    }

    var percentComplete: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}
