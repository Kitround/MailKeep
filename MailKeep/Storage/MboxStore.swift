import Foundation

struct MboxStore {

    // MARK: - URLs

    static func mboxURL(baseDir: URL, account: IMAPAccount, folderName: String, year: Int, month: Int) -> URL {
        let monthStr = String(format: "%02d", month)
        return accountDir(baseDir: baseDir, account: account)
            .appendingPathComponent("\(sanitize(folderName))_\(year)-\(monthStr).mbox")
    }

    static func mboxURLs(baseDir: URL, account: IMAPAccount, folderName: String) -> [URL] {
        let dir = accountDir(baseDir: baseDir, account: account)
        let prefix = sanitize(folderName) + "_"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "mbox" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func indexURL(baseDir: URL, account: IMAPAccount, folderName: String) -> URL {
        accountDir(baseDir: baseDir, account: account)
            .appendingPathComponent("\(sanitize(folderName))_index.json")
    }

    static func accountDir(baseDir: URL, account: IMAPAccount) -> URL {
        baseDir.appendingPathComponent(accountDirName(account), isDirectory: true)
    }

    // MARK: - Write

    /// Appends a message to an mbox file.
    /// Returns (offset, length): byte position of the "From " line start and total bytes written.
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

        let normalizedStr = String(data: messageData, encoding: .utf8)
            ?? String(data: messageData, encoding: .isoLatin1)
            ?? ""
        let normalized = normalizedStr.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            output.append(contentsOf: (escapeMboxLine(line) + "\n").utf8)
        }
        output.append(contentsOf: "\n".utf8)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            let offset = Int64(handle.seekToEndOfFile())
            handle.write(output)
            handle.closeFile()
            return (offset: offset, length: output.count)
        } else {
            try output.write(to: fileURL, options: .atomic)
            return (offset: 0, length: output.count)
        }
    }

    // MARK: - Read (streaming)

    static func streamMessages(from fileURL: URL, onMessage: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }

        let delimiter = Data("\nFrom ".utf8)
        let chunkSize = 4 * 1024 * 1024
        var buffer = Data()
        var isFirst = true

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            buffer.append(chunk)

            var searchStart = buffer.startIndex
            while let range = buffer.range(of: delimiter, in: searchStart..<buffer.endIndex) {
                let msgData = Data(buffer[searchStart..<range.lowerBound])
                if isFirst {
                    isFirst = false
                    let cleaned = stripMboxFromLine(msgData)
                    if !cleaned.isEmpty { onMessage(unescapeMboxData(cleaned)) }
                } else {
                    if !msgData.isEmpty { onMessage(unescapeMboxData(msgData)) }
                }
                searchStart = range.upperBound
                isFirst = false
            }

            // Trim consumed bytes. withUnsafeBytes forces a genuine heap copy so we never
            // accumulate an NSSubrangeData whose internal offset eventually overflows UInt64
            // in rangeOfData:options:range: → NSRangeException.
            if searchStart > 0 && searchStart < buffer.endIndex {
                buffer = buffer.withUnsafeBytes { src in
                    Data(bytes: src.baseAddress!.advanced(by: searchStart),
                         count: src.count - searchStart)
                }
            } else if searchStart >= buffer.endIndex {
                buffer = Data()
            }
            if chunk.isEmpty { break }
        }

        if !buffer.isEmpty {
            let msg = isFirst ? stripMboxFromLine(buffer) : buffer
            let unescaped = unescapeMboxData(msg)
            if !unescaped.isEmpty { onMessage(unescaped) }
        }
    }

    static func readMessages(from fileURL: URL) throws -> [Data] {
        var result: [Data] = []
        try streamMessages(from: fileURL) { result.append($0) }
        return result
    }

    /// Reads each message along with its IMAP-format internal date parsed from the
    /// "From <sender> <ctime>" separator line. Returns nil for the date if it cannot
    /// be parsed — caller should pass nil to APPEND in that case.
    static func readMessagesWithInternalDate(from fileURL: URL) throws -> [(data: Data, internalDate: String?)] {
        let ranges = try messageRanges(in: fileURL)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }

        var result: [(Data, String?)] = []
        for (offset, length) in ranges {
            handle.seek(toFileOffset: UInt64(offset))
            let raw = handle.readData(ofLength: length)
            let block = raw.withUnsafeBytes { src in
                src.count > 0 ? Data(bytes: src.baseAddress!, count: src.count) : Data()
            }
            let fromLine = extractFromLine(block)
            let internalDate = fromLine.flatMap(ctimeToImapDate(fromMboxFromLine:))
            let body = unescapeMboxData(stripMboxFromLine(block))
            result.append((body, internalDate))
        }
        return result
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

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        guard let date = parser.date(from: ctime) else { return nil }
        return imapDate(from: date)
    }

    /// Date → "02-Jan-2006 15:04:05 +0000" (IMAP RFC 3501 INTERNALDATE format)
    static func imapDate(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    // MARK: - Random access (for index-based loading)

    /// Returns (offset, length) pairs for every message block in an mbox file.
    /// offset = byte position of 'F' in the "From " separator line.
    /// length = byte length of the block (up to the \n before the next "From ").
    static func messageRanges(in fileURL: URL) throws -> [(offset: Int64, length: Int)] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }

        let delimiter = Data("\nFrom ".utf8)  // \n + "From "
        let chunkSize = 512 * 1024
        var buffer = Data()
        var bufferBase: Int64 = 0   // file offset of buffer[0]
        var msgStart: Int64 = 0     // file offset of current message's 'F'
        var results: [(Int64, Int)] = []

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
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
        defer { handle.closeFile() }
        handle.seek(toFileOffset: UInt64(offset))
        // readData returns NSData bridged to Data; force a genuine heap copy to ensure
        // we never hold an NSSubrangeData that causes rangeOfData overflow.
        let raw = handle.readData(ofLength: length)
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
        let preview = data.prefix(8192)
        let text = String(data: preview, encoding: .utf8) ?? ""
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

    static func imapdateToCtime(_ imap: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        let cleaned = imap.trimmingCharacters(in: .whitespaces)
        if let date = formatter.date(from: cleaned) {
            let ctime = DateFormatter()
            ctime.locale = Locale(identifier: "en_US_POSIX")
            ctime.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
            return ctime.string(from: date)
        }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        return fallback.string(from: Date())
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

    private static func escapeMboxLine(_ line: String) -> String {
        if line.hasPrefix("From ") { return ">" + line }
        var idx = line.startIndex
        var gtCount = 0
        while idx < line.endIndex && line[idx] == ">" { gtCount += 1; idx = line.index(after: idx) }
        if gtCount > 0 && line[idx...].hasPrefix("From ") { return ">" + line }
        return line
    }
}
