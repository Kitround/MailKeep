import Foundation

enum IMAPResponseLine {
    case tagged(tag: String, status: TaggedStatus, text: String)
    case untagged(keyword: String, rest: String)
    case untaggedWithLiteral(keyword: String, header: String, body: Data)
    case continuation(text: String)

    enum TaggedStatus {
        case ok, no, bad
        static func from(_ s: String) -> TaggedStatus {
            switch s.uppercased() {
            case "OK": return .ok
            case "NO": return .no
            default: return .bad
            }
        }
    }
}

struct FolderStatus {
    var name: String
    var exists: UInt32 = 0
    var uidValidity: UInt32 = 0
    var uidNext: UInt32 = 0
}

struct FetchedMessage {
    var uid: UInt32
    var rfc822: Data
    var internalDate: String
}

struct CollectedResponse {
    var tagged: IMAPResponseLine
    var untagged: [IMAPResponseLine]
    var literalBody: Data?
}
