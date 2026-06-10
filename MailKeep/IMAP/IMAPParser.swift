import Foundation

enum IMAPParser {

    static func parseLine(_ line: String) -> IMAPResponseLine {
        if line.hasPrefix("+ ") {
            return .continuation(text: String(line.dropFirst(2)))
        }
        if line.hasPrefix("* ") {
            let rest = String(line.dropFirst(2))
            let parts = rest.split(separator: " ", maxSplits: 1)
            let keyword = parts.first.map(String.init) ?? ""
            let remainder = parts.count > 1 ? String(parts[1]) : ""
            return .untagged(keyword: keyword, rest: remainder)
        }
        // Tagged: "A001 OK ..." or "A001 NO ..."
        let parts = line.split(separator: " ", maxSplits: 2)
        if parts.count >= 2 {
            let tag = String(parts[0])
            let statusStr = String(parts[1])
            let text = parts.count > 2 ? String(parts[2]) : ""
            let status = IMAPResponseLine.TaggedStatus.from(statusStr)
            return .tagged(tag: tag, status: status, text: text)
        }
        return .untagged(keyword: line, rest: "")
    }

    static func extractLiteralSize(from line: String) -> Int? {
        guard line.hasSuffix("}") else { return nil }
        guard let open = line.lastIndex(of: "{") else { return nil }
        let sizeStr = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return Int(sizeStr)
    }

    // Quote an IMAP string, escaping backslash and double-quote
    static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // Parse "* LIST (\HasNoChildren) "/" "INBOX"" → folder name
    static func parseFolderName(from line: String) -> String? {
        // Remove flags section in parens
        var rest = line
        if let closeFlags = rest.firstIndex(of: ")") {
            rest = String(rest[rest.index(after: closeFlags)...]).trimmingCharacters(in: .whitespaces)
        }
        // Skip delimiter
        let parts = rest.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let namePart = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // Unquote
        if namePart.hasPrefix("\"") && namePart.hasSuffix("\"") {
            return String(namePart.dropFirst().dropLast())
        }
        return namePart
    }

    // Parse "* SEARCH 1 2 3 100" → [1, 2, 3, 100]
    static func parseSearchUIDs(from rest: String) -> [UInt32] {
        rest.split(separator: " ").compactMap { UInt32($0) }
    }

    // Parse EXISTS count from "* 5 EXISTS"
    static func parseExists(keyword: String, rest: String) -> UInt32? {
        if rest.uppercased().hasPrefix("EXISTS") {
            return UInt32(keyword)
        }
        return nil
    }

    // Parse UIDVALIDITY from "* OK [UIDVALIDITY 1234567890] UIDs valid"
    static func parseUIDValidity(from line: String) -> UInt32? {
        parseOKBracket("UIDVALIDITY", from: line)
    }

    static func parseUIDNext(from line: String) -> UInt32? {
        parseOKBracket("UIDNEXT", from: line)
    }

    private static func parseOKBracket(_ key: String, from line: String) -> UInt32? {
        let upper = line.uppercased()
        guard let keyRange = upper.range(of: "[\(key) ") else { return nil }
        let after = line[keyRange.upperBound...]
        let value = after.prefix(while: { $0.isNumber })
        return UInt32(value)
    }

    // Extract UID from "* N FETCH (UID 42 ...)"
    static func parseUID(from rest: String) -> UInt32? {
        let upper = rest.uppercased()
        guard let range = upper.range(of: "UID ") else { return nil }
        let after = rest[range.upperBound...]
        let digits = after.prefix(while: { $0.isNumber })
        return UInt32(digits)
    }

    // Extract INTERNALDATE value (quoted string) from FETCH response
    static func parseInternalDate(from line: String) -> String {
        guard let start = line.range(of: "INTERNALDATE \"") else { return "" }
        let after = line[start.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return "" }
        return String(after[..<end])
    }
}
