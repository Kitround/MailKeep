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
    }

    // MARK: - Body parsing

    private static func parseBodyPart(data: Data, headers: [String: String], into msg: inout EmailMessage) {
        let contentType = headers["content-type"] ?? "text/plain"
        let ctLower = contentType.lowercased()
        let disposition = headers["content-disposition"] ?? ""
        let dispLower = disposition.lowercased()
        let transferEncoding = (headers["content-transfer-encoding"] ?? "7bit")
            .lowercased().trimmingCharacters(in: .whitespaces)
        let charset = extractCharset(from: contentType)

        // Multipart: recurse into all sub-parts
        if ctLower.contains("multipart") {
            let boundary = extractBoundary(from: contentType)
            for partData in splitMultipart(data, boundary: boundary) {
                let (ph, pb) = splitData(partData)
                let partHeaders = parseHeaders(toString7bit(ph))
                parseBodyPart(data: pb, headers: partHeaders, into: &msg)
            }
            return
        }

        // Explicit attachment disposition → collect as attachment
        if dispLower.hasPrefix("attachment") {
            if let att = makeAttachment(data: data, contentType: contentType,
                                        disposition: disposition, encoding: transferEncoding) {
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

        // Non-text, non-multipart (image/*, application/*, etc.) → attachment
        if let att = makeAttachment(data: data, contentType: contentType,
                                    disposition: disposition, encoding: transferEncoding) {
            msg.attachments.append(att)
        }
    }

    // MARK: - Attachment helpers

    private static func makeAttachment(data: Data, contentType: String,
                                       disposition: String, encoding: String) -> EmailAttachment? {
        guard !data.isEmpty else { return nil }
        let mimeType = contentType.components(separatedBy: ";")
            .first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "application/octet-stream"
        let filename = extractFilename(from: contentType, disposition: disposition)
                    ?? fallbackFilename(for: mimeType)

        let decoded: Data
        switch encoding {
        case "base64":
            let text = (String(data: data, encoding: .ascii) ?? "")
                .components(separatedBy: .newlines).joined()
            decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            let text = String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .utf8) ?? ""
            decoded = decodeQP(text)
        default:
            decoded = data
        }
        guard !decoded.isEmpty else { return nil }
        return EmailAttachment(filename: filename, mimeType: mimeType, data: decoded)
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
                    let decoded = decodeHeaderValue(raw)
                    if !decoded.isEmpty { return decoded }
                }
            }
        }
        return nil
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
            let text = String(data: data, encoding: .ascii) ?? ""
            let cleaned = text.components(separatedBy: .newlines).joined()
            if let decoded = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) {
                return bytesToString(decoded, charset: charset)
            }
            return bytesToString(data, charset: charset)

        case "quoted-printable":
            // QP input is ASCII text — decode =XX sequences to raw bytes, then apply charset
            let text = String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .utf8)
                ?? ""
            let decoded = decodeQP(text)
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
    private static func decodeQP(_ input: String) -> Data {
        var out = Data()
        out.reserveCapacity(input.utf8.count)
        var i = input.startIndex

        while i < input.endIndex {
            let c = input[i]
            guard c == "=" else {
                // Regular ASCII byte
                out.append(UInt8(c.asciiValue ?? UInt8(c.unicodeScalars.first!.value & 0x7F)))
                i = input.index(after: i)
                continue
            }
            let i1 = input.index(after: i)
            guard i1 < input.endIndex else { break }

            let c1 = input[i1]
            // Soft line break: =\r\n or =\n
            if c1 == "\r" || c1 == "\n" {
                i = input.index(after: i1)
                if c1 == "\r", i < input.endIndex, input[i] == "\n" {
                    i = input.index(after: i)
                }
                continue
            }
            let i2 = input.index(after: i1)
            if i2 < input.endIndex, let byte = UInt8(String(input[i1...i2]), radix: 16) {
                out.append(byte)
                i = input.index(after: i2)
            } else {
                out.append(UInt8(ascii: "="))
                i = input.index(after: i)
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
                let data = decodeQP(qText)
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

    private static func parseDate(_ value: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm Z",
        ]
        let cleaned = value.trimmingCharacters(in: .whitespaces)
        // Strip trailing comment like "(UTC)"
        let noComment: String
        if let paren = cleaned.firstIndex(of: "(") {
            noComment = String(cleaned[..<paren]).trimmingCharacters(in: .whitespaces)
        } else {
            noComment = cleaned
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            df.dateFormat = fmt
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
