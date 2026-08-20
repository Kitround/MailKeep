import Foundation

enum EmailParser {

    // MARK: - Public

    /// Parse headers only from RFC 2822 data — fast, used for list display.
    static func parseHeadersOnly(data: Data) -> EmailMessage {
        let (headerData, bodyPreview) = splitData(data)
        let headers = parseHeaders(toString7bit(headerData))
        var msg = EmailMessage()
        fillHeaders(&msg, from: headers)
        msg.hasAttachments = detectHasAttachments(headers: headers, bodyPreview: bodyPreview)
        return msg
    }

    /// Heuristic: detect attachments without fully parsing the MIME tree.
    private static func detectHasAttachments(headers: [String: String], bodyPreview: Data) -> Bool {
        let ct = (headers["content-type"] ?? "").lowercased()
        // multipart/mixed is the primary indicator of attachments
        if ct.contains("multipart/mixed") { return true }
        // Scan the first 32 KB for explicit attachment disposition markers.
        // Use Data(…) to force a zero-based copy — prefix() returns a SubSequence that
        // preserves the original slice indices, which causes NSRange overflow in rangeOfData.
        let preview = Data(bodyPreview.prefix(32_768))
        let markers: [String] = [
            "Content-Disposition: attachment",
            "Content-Disposition: Attachment",
            "content-disposition: attachment",
        ]
        return markers.contains { preview.range(of: Data($0.utf8)) != nil }
    }

    /// Parse headers from a raw mbox block (includes "From " separator line).
    static func parseHeadersOnly(mboxBlock: Data) -> EmailMessage {
        parseHeadersOnly(data: MboxStore.processBlock(mboxBlock))
    }

    /// Fill body into an already header-parsed message (called on selection).
    static func parseBody(into msg: inout EmailMessage) {
        let data: Data
        if let url = msg.mboxFileURL, msg.mboxLength > 0 {
            data = (try? MboxStore.readMessage(at: msg.mboxOffset, length: msg.mboxLength, from: url))
                ?? msg.rawData ?? Data()
        } else {
            data = msg.rawData ?? Data()
        }
        let full = parse(data: data)
        msg.bodyText = full.bodyText
        msg.bodyHTML = full.bodyHTML
        msg.attachments = full.attachments
        if !full.attachments.isEmpty { msg.hasAttachments = true }
    }

    static func parse(data: Data) -> EmailMessage {
        let (headerData, bodyData) = splitData(data)
        let headers = parseHeaders(toString7bit(headerData))

        var msg = EmailMessage()
        fillHeaders(&msg, from: headers)
        parseBodyPart(data: bodyData, headers: headers, into: &msg)
        return msg
    }

    // MARK: - Header filling

    private static func fillHeaders(_ msg: inout EmailMessage, from headers: [String: String]) {
        msg.from    = decodeHeaderValue(headers["from"]    ?? "")
        msg.to      = decodeHeaderValue(headers["to"]      ?? "")
        msg.cc      = decodeHeaderValue(headers["cc"]      ?? "")
        msg.subject = decodeHeaderValue(headers["subject"] ?? "").nonEmptyOrDefault("(Sans sujet)")
        msg.date    = parseDate(headers["date"] ?? "")
        msg.messageID  = headers["message-id"]?.trimmingCharacters(in: .whitespaces)
        msg.inReplyTo  = headers["in-reply-to"]?.trimmingCharacters(in: .whitespaces)
        msg.references = headers["references"]?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Body parsing

    /// How deep the MIME tree may nest before parsing gives up.
    ///
    /// Every level of `multipart` recurses, and the messages being parsed come off an IMAP
    /// server — hostile input by nature. A message nesting a few thousand multiparts, under
    /// 1 MB on the wire, drove the recursion straight through the stack guard: SIGSEGV
    /// while backing up, before the user ever opened the mail. Real mail nests a handful of
    /// levels; anything past this is malformed or malicious, and its remaining parts are
    /// dropped rather than followed.
    private static let maxMIMEDepth = 64

    /// How many parts one message may contribute as attachments.
    ///
    /// `maxMIMEDepth` bounds how deep the tree goes, nothing bounded how wide it is: a 1 MB
    /// message made of 20 000 sibling parts parsed in a quarter of a second and left 20 000
    /// decoded buffers in memory, one chip each in the viewer. Depth and breadth are the
    /// same attack, and real mail carries a few dozen parts at most.
    private static let maxAttachments = 200

    private static func parseBodyPart(data: Data, headers: [String: String],
                                      into msg: inout EmailMessage, depth: Int = 0) {
        let contentType = headers["content-type"] ?? "text/plain"
        let ctLower = contentType.lowercased()
        let disposition = headers["content-disposition"] ?? ""
        let dispLower = disposition.lowercased()
        let transferEncoding = (headers["content-transfer-encoding"] ?? "7bit")
            .lowercased().trimmingCharacters(in: .whitespaces)
        let charset = extractCharset(from: contentType)

        // Multipart: recurse into all sub-parts
        if ctLower.contains("multipart") {
            guard depth < maxMIMEDepth else { return }
            let boundary = extractBoundary(from: contentType)
            for partData in splitMultipart(data, boundary: boundary) {
                guard msg.attachments.count < maxAttachments else { return }
                let (ph, pb) = splitData(partData)
                let partHeaders = parseHeaders(toString7bit(ph))
                parseBodyPart(data: pb, headers: partHeaders, into: &msg, depth: depth + 1)
            }
            return
        }

        // Explicit attachment disposition → collect as attachment
        if dispLower.hasPrefix("attachment") {
            if msg.attachments.count < maxAttachments,
               let att = makeAttachment(data: data, contentType: contentType,
                                        disposition: disposition, encoding: transferEncoding,
                                        contentID: headers["content-id"]) {
                msg.attachments.append(att)
            }
            return
        }

        // Text parts → body
        if ctLower.contains("text/html") {
            if msg.bodyHTML == nil {
                msg.bodyHTML = decodeBody(data, encoding: transferEncoding, charset: charset)
            }
            return
        }
        if ctLower.contains("text/plain") || ctLower.isEmpty || !ctLower.contains("/") {
            if msg.bodyText == nil {
                msg.bodyText = decodeBody(data, encoding: transferEncoding, charset: charset)
            }
            return
        }

        // Non-text, non-multipart (image/*, application/*, etc.) → attachment.
        // Inline images (cid:) keep their Content-ID so the archiver can resolve them.
        if msg.attachments.count < maxAttachments,
           let att = makeAttachment(data: data, contentType: contentType,
                                    disposition: disposition, encoding: transferEncoding,
                                    contentID: headers["content-id"]) {
            msg.attachments.append(att)
        }
    }

    // MARK: - Attachment helpers

    private static func makeAttachment(data: Data, contentType: String,
                                       disposition: String, encoding: String,
                                       contentID: String?) -> EmailAttachment? {
        guard !data.isEmpty else { return nil }
        let mimeType = contentType.components(separatedBy: ";")
            .first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "application/octet-stream"
        let filename = extractFilename(from: contentType, disposition: disposition)
                    ?? fallbackFilename(for: mimeType)

        let decoded: Data
        switch encoding {
        case "base64":
            // Decoded straight from the bytes. Going through `String(encoding: .ascii)`
            // first returned nil on any 8-bit byte — a single stray one in the base64
            // stream emptied the buffer, and the attachment was dropped without a word.
            // `.ignoreUnknownCharacters` skips the newlines and whatever else is in there.
            decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            decoded = decodeQP(data)
        default:
            decoded = data
        }
        guard !decoded.isEmpty else { return nil }
        let cid = contentID?.trimmingCharacters(in: .init(charactersIn: "<> \t\r\n"))
        return EmailAttachment(filename: filename, mimeType: mimeType, data: decoded,
                               contentID: cid?.isEmpty == false ? cid : nil,
                               isInline: disposition.lowercased().contains("inline"))
    }

    private static func extractFilename(from contentType: String, disposition: String) -> String? {
        // 1. Content-Disposition filename= or filename*=
        for header in [disposition, contentType] {
            let lower = header.lowercased()
            for key in ["filename*=utf-8''", "filename*=", "filename=", "name="] {
                if let r = lower.range(of: key) {
                    var raw = String(header[r.upperBound...])
                        .trimmingCharacters(in: .init(charactersIn: "\"' \t"))
                    if let semi = raw.firstIndex(of: ";") { raw = String(raw[..<semi]) }
                    raw = raw.trimmingCharacters(in: .init(charactersIn: "\"' \t\r\n"))
                    // URL-decode for filename*=
                    if key.contains("*") {
                        raw = raw.removingPercentEncoding ?? raw
                    }
                    let decoded = safeFilename(decodeHeaderValue(raw))
                    if !decoded.isEmpty { return decoded }
                }
            }
        }
        return nil
    }

    /// Reduces an attachment name to a plain filename, never a path.
    ///
    /// The name comes straight out of a message header, so it is attacker-controlled: it
    /// arrived here containing `../../../../etc/passwd` and kept its separators all the way
    /// to the save panel. Only the last path component survives, and a leading dot cannot
    /// turn the result into `..`.
    ///
    /// Bidirectional overrides go too: they reverse how the rest of the name is drawn, so a
    /// file whose real extension is `.exe` can be made to read as `.jpg` on screen. The
    /// extension the user sees must be the one on disk.
    private static func safeFilename(_ name: String) -> String {
        let flattened = name
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        let cleaned = String(flattened.unicodeScalars.filter { scalar in
            // C0/C1 controls, and the bidi overrides and isolates (U+202A…U+202E, U+2066…U+2069).
            !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
              || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value))
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) { return "" }
        return cleaned
    }

    private static func fallbackFilename(for mimeType: String) -> String {
        let ext: String
        switch mimeType {
        case "application/pdf":                 ext = "pdf"
        case "image/jpeg":                      ext = "jpg"
        case "image/png":                       ext = "png"
        case "image/gif":                       ext = "gif"
        case "image/webp":                      ext = "webp"
        case "audio/mpeg":                      ext = "mp3"
        case "video/mp4":                       ext = "mp4"
        case "application/zip":                 ext = "zip"
        case "application/x-zip-compressed":    ext = "zip"
        case "text/plain":                      ext = "txt"
        case "text/csv":                        ext = "csv"
        default:
            ext = mimeType.components(separatedBy: "/").last ?? "bin"
        }
        return "pièce_jointe.\(ext)"
    }

    // MARK: - Data splitting

    private static func splitData(_ rawData: Data) -> (Data, Data) {
        // Normalize to zero-based so NSRange operations never see a negative location
        let data = rawData.startIndex == 0 ? rawData : Data(rawData)
        // Prefer \r\n\r\n, fall back to \n\n
        for sep in ["\r\n\r\n", "\n\n"] {
            if let r = data.range(of: Data(sep.utf8)) {
                return (Data(data[..<r.lowerBound]), Data(data[r.upperBound...]))
            }
        }
        return (data, Data())
    }

    // Headers are 7-bit ASCII (encoded words for non-ASCII) — safe to read as UTF-8/latin1
    private static func toString7bit(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: - Header parsing (handles folded headers)

    private static func parseHeaders(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        var current = ""

        func commit() {
            guard let colon = current.firstIndex(of: ":") else { current = ""; return }
            let key = String(current[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let val = String(current[current.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if headers[key] == nil { headers[key] = val }
            current = ""
        }

        for line in raw.components(separatedBy: "\n") {
            let s = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if s.hasPrefix(" ") || s.hasPrefix("\t") {
                current += " " + s.trimmingCharacters(in: .whitespaces)
            } else {
                commit()
                current = s
            }
        }
        commit()
        return headers
    }

    // MARK: - MIME helpers

    private static func extractCharset(from contentType: String) -> String {
        let lower = contentType.lowercased()
        guard let r = lower.range(of: "charset=") else { return "utf-8" }
        var s = String(contentType[r.upperBound...])
            .trimmingCharacters(in: .init(charactersIn: "\"' \t"))
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
        let result = s.trimmingCharacters(in: .init(charactersIn: "\"' \t\r\n")).lowercased()
        return result.isEmpty ? "utf-8" : result
    }

    private static func extractBoundary(from contentType: String) -> String {
        let lower = contentType.lowercased()
        guard let r = lower.range(of: "boundary=") else { return "" }
        var s = String(contentType[r.upperBound...])
            .trimmingCharacters(in: .init(charactersIn: "\"' \t"))
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
        return s.trimmingCharacters(in: .init(charactersIn: "\"' \t\r\n"))
    }

    private static func splitMultipart(_ rawData: Data, boundary: String) -> [Data] {
        guard !boundary.isEmpty else { return [] }
        // Always work on a zero-based copy — slices bridged from NSData can have non-zero
        // startIndex which makes NSRange.location negative and crashes rangeOfData:options:range:
        let data = rawData.startIndex == 0 ? rawData : Data(rawData)
        let delim    = Data(("--" + boundary).utf8)
        let endDelim = Data(("--" + boundary + "--").utf8)
        var parts: [Data] = []
        var pos = 0 // always zero-based after the copy above

        while let r = data.range(of: delim, in: pos..<data.endIndex) {
            // End delimiter
            if data[r.upperBound...].starts(with: Data("--".utf8)) { break }
            if data[r.lowerBound...].starts(with: endDelim) { break }

            // Skip to end of delimiter line
            var contentStart = r.upperBound
            while contentStart < data.endIndex && data[contentStart] != UInt8(ascii: "\n") {
                contentStart = data.index(after: contentStart)
            }
            if contentStart < data.endIndex { contentStart = data.index(after: contentStart) }

            // Find next delimiter
            guard let next = data.range(of: delim, in: contentStart..<data.endIndex) else {
                parts.append(Data(data[contentStart...]))
                break
            }
            // Trim trailing CRLF before next delimiter
            var end = next.lowerBound
            if end > contentStart && data[data.index(before: end)] == UInt8(ascii: "\n") {
                end = data.index(before: end)
            }
            if end > contentStart && data[data.index(before: end)] == UInt8(ascii: "\r") {
                end = data.index(before: end)
            }
            parts.append(Data(data[contentStart..<end]))
            pos = next.lowerBound
        }
        return parts
    }

    // MARK: - Body decoding

    private static func decodeBody(_ data: Data, encoding: String, charset: String) -> String {
        switch encoding {
        case "base64":
            // Byte level, for the same reason as in `makeAttachment`: one 8-bit byte in the
            // base64 stream used to blank the whole body.
            if let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
               !decoded.isEmpty {
                return bytesToString(decoded, charset: charset)
            }
            return bytesToString(data, charset: charset)

        case "quoted-printable":
            // Decode =XX sequences + soft line breaks at byte level, then apply charset.
            let decoded = decodeQP(data)
            return bytesToString(decoded, charset: charset)

        default: // 7bit, 8bit, binary
            return bytesToString(data, charset: charset)
        }
    }

    /// Convert raw bytes to String using the charset declared in Content-Type.
    private static func bytesToString(_ data: Data, charset: String) -> String {
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cfEnc != kCFStringEncodingInvalidId {
            let nsEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
            if let s = String(data: data, encoding: nsEnc) { return s }
        }
        // Fallbacks
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    /// Decode quoted-printable to raw bytes (NOT to String — charset is applied after).
    /// Operates on bytes, never Swift Characters: "\r\n" is a single grapheme cluster,
    /// so iterating Characters would miss "=\r\n" soft line breaks and corrupt the output.
    private static func decodeQP(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data()
        out.reserveCapacity(bytes.count)
        let eq = UInt8(ascii: "="), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")

        func hexValue(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30          // 0-9
            case 0x41...0x46: return b - 0x41 + 10      // A-F
            case 0x61...0x66: return b - 0x61 + 10      // a-f
            default:          return nil
            }
        }

        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b == eq else { out.append(b); i += 1; continue }
            guard i + 1 < bytes.count else { break }
            let n1 = bytes[i + 1]
            // Soft line break: =\r\n or =\n
            if n1 == cr || n1 == lf {
                i += 2
                if n1 == cr, i < bytes.count, bytes[i] == lf { i += 1 }
                continue
            }
            // =XX hex escape
            if i + 2 < bytes.count, let hi = hexValue(n1), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(eq)
                i += 1
            }
        }
        return out
    }

    // MARK: - RFC 2047 encoded words in headers

    static func decodeHeaderValue(_ value: String) -> String {
        var result = value
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let nsVal = value as NSString
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))

        for match in matches.reversed() {
            guard match.numberOfRanges == 4 else { continue }
            let charset  = nsVal.substring(with: match.range(at: 1))
            let encoding = nsVal.substring(with: match.range(at: 2)).uppercased()
            let encoded  = nsVal.substring(with: match.range(at: 3))

            var decoded: String?
            if encoding == "B" {
                if let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
                    decoded = bytesToString(data, charset: charset.lowercased())
                }
            } else { // Q encoding
                let qText = encoded.replacingOccurrences(of: "_", with: " ")
                let data = decodeQP(Data(qText.utf8))
                decoded = bytesToString(data, charset: charset.lowercased())
            }

            if let d = decoded, let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: d)
            }
        }
        // Clean up adjacent encoded-word spaces: "word1?= =?word2" → "word1word2"
        result = result.replacingOccurrences(of: "\\?= =\\?", with: "", options: .regularExpression)
        return result
    }

    // MARK: - Date parsing

    // One immutable formatter per format — DateFormatter is costly to allocate, and
    // parse() runs off the main thread on many messages. Created once and never
    // mutated, so concurrent `date(from:)` reads are safe.
    private static let dateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss z",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm Z",
    ].map { fmt -> DateFormatter in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f
    }

    private static func parseDate(_ value: String) -> Date? {
        let cleaned = value.trimmingCharacters(in: .whitespaces)
        // Strip trailing comment like "(UTC)"
        let noComment: String
        if let paren = cleaned.firstIndex(of: "(") {
            noComment = String(cleaned[..<paren]).trimmingCharacters(in: .whitespaces)
        } else {
            noComment = cleaned
        }
        for df in dateFormatters {
            if let d = df.date(from: noComment) { return d }
        }
        return nil
    }
}

private extension String {
    func nonEmptyOrDefault(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
