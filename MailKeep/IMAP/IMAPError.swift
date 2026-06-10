import Foundation

enum IMAPError: Error, LocalizedError {
    case connectionFailed(String)
    case authenticationFailed(String)
    case commandFailed(tag: String, response: String)
    case unexpectedResponse(String)
    case serverDisconnected
    case timeout
    case parseError(String)
    case literalTooLarge(Int)
    case folderNotFound(String)
    case appendFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let s): return "Connexion impossible : \(s)"
        case .authenticationFailed(let s): return "Authentification échouée : \(s)"
        case .commandFailed(let tag, let r): return "Commande \(tag) refusée : \(r)"
        case .unexpectedResponse(let s): return "Réponse inattendue : \(s)"
        case .serverDisconnected: return "Déconnecté du serveur"
        case .timeout: return "Délai d'attente dépassé"
        case .parseError(let s): return "Erreur de parsing : \(s)"
        case .literalTooLarge(let n): return "Literal trop grand : \(n) octets"
        case .folderNotFound(let s): return "Dossier introuvable : \(s)"
        case .appendFailed(let s): return "Réinjection échouée : \(s)"
        }
    }
}
