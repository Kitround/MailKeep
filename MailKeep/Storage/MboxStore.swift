import Foundation

struct MboxStore {

    // Cached formatters — DateFormatter is costly to allocate and these run once per
    // backed-up message. Created once, never mutated → safe to read concurrently.
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static func makeFormatter(_ format: String, utc: Bool = false) -> DateFormatter {
        let f = DateFormatter()
        f.locale = posix
        if utc { f.timeZone = TimeZone(identifier: "UTC") }
        f.dateFormat = format
        return f
    }
    private static let imapInFormatter   = makeFormatter("d-MMM-yyyy HH:mm:ss Z")
    private static let ctimeOutFormatter = makeFormatter("EEE MMM dd HH:mm:ss yyyy")
    private static let ctimeInFormatter  = makeFormatter("EEE MMM dd HH:mm:ss yyyy", utc: true)
    private static let imapOutFormatter  = makeFormatter("dd-MMM-yyyy HH:mm:ss Z", utc: true)

    // MARK: - URLs

    static func mboxURL(baseDir: URL, account: IMAPAccount, folderName: String, year: Int, month: Int) -> URL {
        let monthStr = String(format: "%02d", month)
        return accountDir(baseDir: baseDir, account: account)
            .appendingPathComponent("\(sanitize(folderName))_\(year)-\(monthStr).mbox")
    }

    static func mboxURLs(baseDir: URL, account: IMAPAccount, folderName: String) -> [URL] {
        let dir = accountDir(baseDir: baseDir, account: account)
        let safe = sanitize(folderName)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { isMbox($0.lastPathComponent, ofFolder: safe) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// True when the file is a .mbox belonging to THIS exact folder.
    /// A bare prefix is not enough: `sanitize` turns `/` into `_`, so "INBOX" would catch
    /// "INBOX_Travail_2026-08.mbox" (the INBOX/Travail folder) and "INBOXOLD_2026-08.mbox".
    /// The suffix has to be either a period or an import stamp.
    static func isMbox(_ filename: String, ofFolder safeFolder: String) -> Bool {
        guard let rest = suffixAfterFolder(filename, safeFolder, extension: "mbox") else { return false }
        return isPeriod(rest) || isImportStamp(rest)
    }

    /// True when the file is a .eml archive of THIS folder: "<safe>_<period>_<offset>.eml".
    static func isArchive(_ filename: String, ofFolder safeFolder: String) -> Bool {
        guard let rest = suffixAfterFolder(filename, safeFolder, extension: "eml"),
              let lastUnderscore = rest.lastIndex(of: "_") else { return false }
        let period = String(rest[rest.startIndex..<lastUnderscore])
        let offset = rest[rest.index(after: lastUnderscore)...]
        guard !offset.isEmpty, offset.allSatisfy(\.isNumber) else { return false }
        return isPeriod(period) || isImportStamp(period)
    }

    /// "INBOX_2026-08.mbox" + "INBOX" → "2026-08". nil when the name belongs to another
    /// folder or to another extension.
    private static func suffixAfterFolder(_ filename: String, _ safeFolder: String, extension ext: String) -> String? {
        let prefix = safeFolder + "_"
        let suffix = "." + ext
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return String(filename[start..<end])
    }

    /// "2026-08"
    private static func isPeriod(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// "imported_20260806_143012" or "imported_20260806_143012_2"
    private static func isImportStamp(_ s: String) -> Bool {
        let parts = s.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 4, parts[0] == "imported" else { return false }
        return parts.dropFirst().allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func indexURL(baseDir: URL, account: IMAPAccount, folderName: String) -> URL {
        accountDir(baseDir: baseDir, account: account)
            .appendingPathComponent("\(sanitize(folderName))_index.json")
    }

    static func archiveDir(baseDir: URL, account: IMAPAccount) -> URL {
        accountDir(baseDir: baseDir, account: account)
            .appendingPathComponent("archive", isDirectory: true)
    }

    /// Self-contained .eml archive path for one message, keyed by its mbox file +
    /// byte offset — deterministic at both backup time and display time.
    static func archiveURL(baseDir: URL, account: IMAPAccount, mboxFilename: String, offset: Int64) -> URL {
        archiveDir(baseDir: baseDir, account: account)
            .appendingPathComponent("\(archiveBaseName(mboxFilename))_\(offset).eml")
    }

    /// "INBOX_2026-08.mbox" → "INBOX_2026-08". Only the extension goes: a
    /// `replacingOccurrences(of: ".mbox")` also ate a ".mbox" sitting in the middle of the
    /// folder name, and two distinct folders landed on the same file.
    static func archiveBaseName(_ mboxFilename: String) -> String {
        mboxFilename.hasSuffix(".mbox") ? String(mboxFilename.dropLast(5)) : mboxFilename
    }

    static func accountDir(baseDir: URL, account: IMAPAccount) -> URL {
        baseDir.appendingPathComponent(accountDirName(account), isDirectory: true)
    }

    // MARK: - Write

    /// Appends a message to an mbox file.
    /// Returns (offset, length): byte position of the "From " line start and total bytes written.
    /// The message body is processed at byte level — never decoded to String — so non-UTF-8
    /// content (Latin-1, Windows-1252, raw 8-bit) is preserved exactly as received.
    @discardableResult
    static func appendMessage(
        messageData: Data,
        internalDate: String,
        sender: String,
        to fileURL: URL
    ) throws -> (offset: Int64, length: Int) {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fromLine = "From \(sender) \(imapdateToCtime(internalDate))\n"
        var output = Data()
        output.append(contentsOf: fromLine.utf8)
        output.append(escapeMboxData(normalizeToLF(messageData)))
        if output.last != UInt8(ascii: "\n") { output.append(UInt8(ascii: "\n")) }
        output.append(UInt8(ascii: "\n"))

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            let offset = Int64(try handle.seekToEnd())
            try handle.write(contentsOf: output)
            // Without this a crash leaves a truncated final block that the index still
            // references as complete.
            try handle.synchronize()
            return (offset: offset, length: output.count)
        } else {
            try output.write(to: fileURL, options: .atomic)
            return (offset: 0, length: output.count)
        }
    }

    /// CRLF → LF at byte level (lone \r left untouched).
    private static func normalizeToLF(_ data: Data) -> Data {
        let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        guard data.contains(cr) else { return data }
        var out = Data()
        out.reserveCapacity(data.count)
        var i = data.startIndex
        while i < data.endIndex {
            let b = data[i]
            let next = data.index(after: i)
            if b == cr, next < data.endIndex, data[next] == lf {
                out.append(lf)
                i = data.index(after: next)
            } else {
                out.append(b)
                i = next
            }
        }
        return out
    }

    /// mboxo escaping at byte level: prepend ">" to any line matching />*From / .
    private static func escapeMboxData(_ data: Data) -> Data {
        let fromBytes = Array("From ".utf8)
        let gt = UInt8(ascii: ">"), nl = UInt8(ascii: "\n")
        var out = Data()
        out.reserveCapacity(data.count + 64)
        var i = data.startIndex
        while i < data.endIndex {
            // Inspect line start: skip leading '>' then test for "From "
            var j = i
            while j < data.endIndex && data[j] == gt { j = data.index(after: j) }
            var isFrom = true
            var k = j
            for fb in fromBytes {
                guard k < data.endIndex, data[k] == fb else { isFrom = false; break }
                k = data.index(after: k)
            }
            if isFrom { out.append(gt) }
            // Copy the line through its newline
            while i < data.endIndex {
                let b = data[i]
                out.append(b)
                i = data.index(after: i)
                if b == nl { break }
            }
        }
        return out
    }

    // MARK: - Read

    /// Reads one message block along with the IMAP-format internal date parsed from its
    /// "From <sender> <ctime>" separator line. Returns nil for the date if it cannot be
    /// parsed — caller should pass nil to APPEND in that case. One message at a time:
    /// a restore must never hold a whole multi-gigabyte mbox in memory.
    static func readMessageWithInternalDate(
        at offset: Int64, length: Int, from fileURL: URL
    ) throws -> (data: Data, internalDate: String?) {
        guard offset >= 0, length > 0 else { return (Data(), nil) }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let raw = try handle.read(upToCount: length) ?? Data()
        let block = raw.withUnsafeBytes { src in
            src.count > 0 ? Data(bytes: src.baseAddress!, count: src.count) : Data()
        }
        let internalDate = extractFromLine(block).flatMap(ctimeToImapDate(fromMboxFromLine:))
        return (unescapeMboxData(stripMboxFromLine(block)), internalDate)
    }

    private static func extractFromLine(_ block: Data) -> String? {
        guard let nl = block.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = block[block.startIndex..<nl]
        return String(data: Data(line), encoding: .utf8)
    }

    /// "From sender@host Mon Jan 02 15:04:05 2006" → "02-Jan-2006 15:04:05 +0000"
    static func ctimeToImapDate(fromMboxFromLine line: String) -> String? {
        guard line.hasPrefix("From ") else { return nil }
        let rest = String(line.dropFirst(5))
        // Sender token then space then ctime — find first space.
        guard let firstSpace = rest.firstIndex(of: " ") else { return nil }
        let ctime = String(rest[rest.index(after: firstSpace)...]).trimmingCharacters(in: .whitespaces)

        guard let date = ctimeInFormatter.date(from: ctime) else { return nil }
        return imapDate(from: date)
    }

    /// Date → "02-Jan-2006 15:04:05 +0000" (IMAP RFC 3501 INTERNALDATE format)
    static func imapDate(from date: Date) -> String {
        imapOutFormatter.string(from: date)
    }

    // MARK: - Random access (for index-based loading)

    /// Returns (offset, length) pairs for every message block in an mbox file.
    /// offset = byte position of 'F' in the "From " separator line.
    /// length = byte length of the block (up to the \n before the next "From ").
    static func messageRanges(in fileURL: URL) throws -> [(offset: Int64, length: Int)] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let delimiter = Data("\nFrom ".utf8)  // \n + "From "
        let chunkSize = 512 * 1024
        var buffer = Data()
        var bufferBase: Int64 = 0   // file offset of buffer[0]
        var msgStart: Int64 = 0     // file offset of current message's 'F'
        var results: [(Int64, Int)] = []

        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            buffer.append(chunk)

            var searchFrom = max(0, Int(msgStart - bufferBase))

            while let range = buffer.range(of: delimiter, in: searchFrom..<buffer.endIndex) {
                // The \n at range.lowerBound ends the current message
                let delimFile = bufferBase + Int64(range.lowerBound)
                let msgLen = Int(delimFile - msgStart)
                if msgLen > 0 { results.append((msgStart, msgLen)) }

                // Next message: 'F' is at delimFile + 1 (skip the \n)
                msgStart = delimFile + 1
                searchFrom = range.upperBound
            }

            // Trim buffer up to msgStart (keep a small safety margin).
            // withUnsafeBytes forces a genuine heap copy — removeFirst / slice assignment
            // produces NSSubrangeData whose internal offset accumulates across iterations
            // and eventually overflows in rangeOfData:options:range: → NSRangeException.
            let keepFrom = max(0, Int(msgStart - bufferBase) - 5)
            if keepFrom > 0 {
                bufferBase += Int64(keepFrom)
                let remaining = buffer.count - keepFrom
                buffer = remaining > 0
                    ? buffer.withUnsafeBytes { src in
                        Data(bytes: src.baseAddress!.advanced(by: keepFrom), count: remaining)
                      }
                    : Data()
            }

            if chunk.isEmpty { break }
        }

        // Last message
        let fileEnd = bufferBase + Int64(buffer.count)
        let lastLen = Int(fileEnd - msgStart)
        if lastLen > 0 { results.append((msgStart, lastLen)) }

        return results
    }

    /// Reads a single message block from file and returns the RFC 2822 data.
    static func readMessage(at offset: Int64, length: Int, from fileURL: URL) throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        // read returns NSData bridged to Data; force a genuine heap copy to ensure
        // we never hold an NSSubrangeData that causes rangeOfData overflow.
        let raw = try handle.read(upToCount: length) ?? Data()
        let block = raw.withUnsafeBytes { src in
            src.count > 0 ? Data(bytes: src.baseAddress!, count: src.count) : Data()
        }
        return unescapeMboxData(stripMboxFromLine(block))
    }

    /// Process a raw mbox block (with "From " line) into RFC 2822 data.
    static func processBlock(_ block: Data) -> Data {
        unescapeMboxData(stripMboxFromLine(block))
    }

    // MARK: - Helpers

    static func extractSender(from data: Data) -> String {
        let preview = Data(data.prefix(8192))
        // latin-1 fallback: headers are not always valid UTF-8 (older ISO-8859-1 mail),
        // and the 8 KB cut can land mid multi-byte character. Without the fallback, every
        // affected message lost its sender and its mbox "From" line read
        // "unknown@unknown".
        let text = String(data: preview, encoding: .utf8)
            ?? String(data: preview, encoding: .isoLatin1)
            ?? ""
        for line in text.components(separatedBy: "\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("from:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let open = value.lastIndex(of: "<"),
                   let close = value.lastIndex(of: ">"),
                   open < close {
                    return String(value[value.index(after: open)..<close])
                }
                return value.isEmpty ? "unknown@unknown" : value
            }
        }
        return "unknown@unknown"
    }

    /// Which monthly file a message belongs in, from its INTERNALDATE.
    /// The month is the one in the message's own time zone, not the machine's: otherwise a
    /// message sent 1 August 00:30 +0200 lands in July's file for a reader on UTC-3.
    static func yearMonth(fromInternalDate internalDate: String) -> (year: Int, month: Int) {
        let trimmed = internalDate.trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(fromInternalDate: trimmed) ?? .current
        let date = imapInFormatter.date(from: trimmed) ?? Date()
        let comps = calendar.dateComponents([.year, .month], from: date)
        let now = calendar.dateComponents([.year, .month], from: Date())
        return (comps.year ?? now.year ?? 2000, comps.month ?? now.month ?? 1)
    }

    /// "12-Aug-2026 09:15:00 +0200" → TimeZone(+7200)
    private static func timeZone(fromInternalDate s: String) -> TimeZone? {
        guard let signIndex = s.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let digits = s[s.index(after: signIndex)...].filter(\.isNumber)
        guard digits.count == 4, let value = Int(digits) else { return nil }
        let seconds = (value / 100) * 3600 + (value % 100) * 60
        return TimeZone(secondsFromGMT: s[signIndex] == "-" ? -seconds : seconds)
    }

    static func imapdateToCtime(_ imap: String) -> String {
        let cleaned = imap.trimmingCharacters(in: .whitespaces)
        let date = imapInFormatter.date(from: cleaned) ?? Date()
        return ctimeOutFormatter.string(from: date)
    }

    static func accountDirName(_ account: IMAPAccount) -> String {
        sanitize(account.username + "@" + account.host)
    }

    static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name.components(separatedBy: illegal).joined(separator: "_")
    }

    private static func stripMboxFromLine(_ data: Data) -> Data {
        guard let nl = data.firstIndex(of: UInt8(ascii: "\n")) else { return data }
        let after = data.index(after: nl)
        return after < data.endIndex ? Data(data[after...]) : Data()
    }

    private static func unescapeMboxData(_ data: Data) -> Data {
        guard data.contains(UInt8(ascii: ">")) else { return data }
        var result = Data()
        result.reserveCapacity(data.count)
        var i = data.startIndex
        let gt = UInt8(ascii: ">")
        let nl = UInt8(ascii: "\n")
        let f  = UInt8(ascii: "F")

        while i < data.endIndex {
            let lineStart = i
            var gts = 0
            while i < data.endIndex && data[i] == gt { gts += 1; i = data.index(after: i) }
            if gts > 0 && i < data.endIndex && data[i] == f {
                let fromPrefix = Data("From ".utf8)
                if data[i...].starts(with: fromPrefix) {
                    result.append(Data(repeating: gt, count: gts - 1))
                    while i < data.endIndex && data[i] != nl { result.append(data[i]); i = data.index(after: i) }
                    if i < data.endIndex { result.append(nl); i = data.index(after: i) }
                    continue
                }
            }
            i = lineStart
            while i < data.endIndex && data[i] != nl { result.append(data[i]); i = data.index(after: i) }
            if i < data.endIndex { result.append(nl); i = data.index(after: i) }
        }
        return result
    }

}
