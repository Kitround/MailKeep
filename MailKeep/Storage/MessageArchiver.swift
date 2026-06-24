import Foundation

/// Builds a self-contained `.eml` archive of a message: a valid RFC822 email where
/// remote hot-linked images are fetched and embedded as `cid:` inline parts, inline
/// images are kept, and attachments are preserved. One portable file per mail,
/// re-importable into any mail client and complete even after the sender drops the
/// remote images. Opt-in per account — fetching remote images hits sender servers.
enum MessageArchiver {

    // Safety caps — a hostile message must not exhaust memory or stall a backup.
    private static let maxImages = 40
    private static let maxBytesPerImage = 15 * 1024 * 1024
    private static let maxTotalBytes = 80 * 1024 * 1024
    private static let fetchTimeout: TimeInterval = 12

    // MARK: - Archive (backup time)

    /// Parses the raw message, fetches + inlines remote images, writes a self-contained
    /// `.eml`. Best-effort: individual fetch failures leave that image as its original URL.
    static func archive(rfc822: Data, to url: URL) async {
        let message = await Task.detached { EmailParser.parse(data: rfc822) }.value

        // Existing inline images (cid:) already parsed from the message.
        var relatedImages: [(cid: String, mime: String, data: Data)] =
            message.attachments
                .filter { $0.contentID != nil }
                .map { ($0.contentID!, $0.mimeType, $0.data) }

        // Fetch remote <img src="http…"> and assign them fresh Content-IDs.
        var html = message.bodyHTML
        if let original = html, !original.isEmpty {
            let (rewritten, fetched) = await fetchAndRewrite(html: original)
            html = rewritten
            relatedImages.append(contentsOf: fetched)
        }

        let attachments = message.attachments.filter { $0.contentID == nil }
        let eml = buildEML(message: message, html: html, related: relatedImages, attachments: attachments)

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(eml.utf8).write(to: url, options: .atomic)
        } catch {
            // Archiving is best-effort — never fail the backup over it.
        }
    }

    // MARK: - Render (display time)

    /// Parses an archived `.eml` and returns display HTML with cid: images inlined as
    /// data: URIs — for the in-app offline viewer. No network.
    static func renderHTML(fromEML data: Data) -> String {
        let msg = EmailParser.parse(data: data)
        let base = (msg.bodyHTML?.isEmpty == false)
            ? msg.bodyHTML!
            : "<pre>\(escapeHTML(msg.bodyText ?? ""))</pre>"
        let inlined = inlineCID(in: base, attachments: msg.attachments)
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="UTF-8">
        <meta name="color-scheme" content="light dark">
        <style>
          body { font-family: -apple-system, sans-serif; font-size: 14px; margin: 16px;
                 line-height: 1.5; word-wrap: break-word; }
          img { max-width: 100%; height: auto; }
        </style>
        </head><body>\(inlined)</body></html>
        """
    }

    // MARK: - Remote image fetch

    private static func fetchAndRewrite(html: String) async -> (String, [(cid: String, mime: String, data: Data)]) {
        let pattern = #"src\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return (html, [])
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var result = html
        var fetched: [(String, String, Data)] = []
        var count = 0
        var totalBytes = 0

        // Reverse so earlier ranges stay valid while we splice replacements in.
        for match in matches.reversed() {
            guard match.numberOfRanges == 2 else { continue }
            let src = ns.substring(with: match.range(at: 1))
            let lower = src.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }
            guard count < maxImages else { continue }

            guard let (data, mime) = await fetch(src), data.count <= maxBytesPerImage,
                  totalBytes + data.count <= maxTotalBytes else { continue }
            totalBytes += data.count
            let cid = "mkimg\(count)@mailkeep"
            fetched.append((cid, mime, data))
            count += 1

            if let range = Range(match.range(at: 1), in: result) {
                result.replaceSubrange(range, with: "cid:\(cid)")
            }
        }
        return (result, fetched)
    }

    private static func fetch(_ urlString: String) async -> (Data, String)? {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = fetchTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)

        do {
            var req = URLRequest(url: url)
            req.setValue("MailKeep", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: req)
            guard !data.isEmpty else { return nil }
            let mime = (response.mimeType ?? "").hasPrefix("image/")
                ? response.mimeType!
                : mimeFromExtension(url.pathExtension)
            return (data, mime)
        } catch {
            return nil
        }
    }

    // MARK: - EML assembly

    private static func buildEML(message: EmailMessage, html: String?,
                                 related: [(cid: String, mime: String, data: Data)],
                                 attachments: [EmailAttachment]) -> String {
        // Body: text/plain and/or text/html, wrapped in alternative if both.
        var bodyEntity: String
        let htmlEntity = html.flatMap { $0.isEmpty ? nil : leaf(contentType: "text/html; charset=utf-8", data: Data($0.utf8)) }
        let textEntity = message.bodyText.flatMap { $0.isEmpty ? nil : leaf(contentType: "text/plain; charset=utf-8", data: Data($0.utf8)) }
        switch (textEntity, htmlEntity) {
        case let (t?, h?): bodyEntity = multipart("alternative", parts: [t, h])
        case let (_, h?):  bodyEntity = h
        case let (t?, _):  bodyEntity = t
        default:           bodyEntity = leaf(contentType: "text/plain; charset=utf-8", data: Data())
        }

        // multipart/related wraps the body + inline images referenced by cid.
        var contentEntity = bodyEntity
        if !related.isEmpty {
            let imageParts = related.map {
                leaf(contentType: $0.mime.isEmpty ? "application/octet-stream" : $0.mime,
                     data: $0.data, contentID: $0.cid)
            }
            contentEntity = multipart("related", parts: [bodyEntity] + imageParts)
        }

        // multipart/mixed wraps content + real attachments.
        var topEntity = contentEntity
        if !attachments.isEmpty {
            let attParts = attachments.map {
                leaf(contentType: $0.mimeType.isEmpty ? "application/octet-stream" : $0.mimeType,
                     data: $0.data, filename: $0.filename)
            }
            topEntity = multipart("mixed", parts: [contentEntity] + attParts)
        }

        var headers = ""
        if !message.from.isEmpty { headers += "From: \(encodeHeader(message.from))\r\n" }
        if !message.to.isEmpty   { headers += "To: \(encodeHeader(message.to))\r\n" }
        if !message.cc.isEmpty   { headers += "Cc: \(encodeHeader(message.cc))\r\n" }
        headers += "Subject: \(encodeHeader(message.subject))\r\n"
        if let date = message.date { headers += "Date: \(rfc2822Date(date))\r\n" }
        headers += "Message-ID: <\(UUID().uuidString)@mailkeep>\r\n"
        headers += "X-MailKeep-Archive: 1\r\n"
        headers += "MIME-Version: 1.0\r\n"

        return headers + topEntity
    }

    /// A leaf MIME entity (base64-encoded), beginning with its own Content-Type header.
    private static func leaf(contentType: String, data: Data,
                             contentID: String? = nil, filename: String? = nil) -> String {
        var h = "Content-Type: \(contentType)\r\n"
        h += "Content-Transfer-Encoding: base64\r\n"
        if let contentID { h += "Content-ID: <\(contentID)>\r\n" }
        if let filename {
            h += dispositionHeader(filename: filename)
        }
        let b64 = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return h + "\r\n" + b64 + "\r\n"
    }

    private static func multipart(_ subtype: String, parts: [String]) -> String {
        let boundary = "mk_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var s = "Content-Type: multipart/\(subtype); boundary=\"\(boundary)\"\r\n\r\n"
        for p in parts { s += "--\(boundary)\r\n\(p)" }
        s += "--\(boundary)--\r\n"
        return s
    }

    // MARK: - Helpers

    private static func inlineCID(in html: String, attachments: [EmailAttachment]) -> String {
        guard html.contains("cid:") else { return html }
        var result = html
        for att in attachments where att.contentID != nil {
            let cid = att.contentID!
            let uri = "data:\(att.mimeType.isEmpty ? "application/octet-stream" : att.mimeType);base64,\(att.data.base64EncodedString())"
            for variant in ["cid:\(cid)", "cid:<\(cid)>"] {
                result = result.replacingOccurrences(of: variant, with: uri)
            }
        }
        return result
    }

    private static func encodeHeader(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII }) && !s.contains("\r") && !s.contains("\n") { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    /// Content-Disposition for an attachment. Pure-ASCII names are quoted (with `"`/`\`
    /// escaped); non-ASCII names use RFC 2231 `filename*=UTF-8''…` plus an ASCII fallback.
    private static func dispositionHeader(filename: String) -> String {
        let clean = filename.replacingOccurrences(of: "\r", with: "")
                            .replacingOccurrences(of: "\n", with: "")
        let isASCII = clean.allSatisfy { $0.isASCII }
        if isASCII {
            let escaped = clean.replacingOccurrences(of: "\\", with: "\\\\")
                               .replacingOccurrences(of: "\"", with: "\\\"")
            return "Content-Disposition: attachment; filename=\"\(escaped)\"\r\n"
        }
        let fallback = String(clean.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" ? Character($0) : "_" })
        return "Content-Disposition: attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(rfc2231Encode(clean))\r\n"
    }

    private static func rfc2231Encode(_ s: String) -> String {
        // attr-char set per RFC 2231 / 5987 — everything else is percent-encoded.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")
        var out = ""
        for byte in Data(s.utf8) {
            let scalar = UnicodeScalar(byte)
            if scalar.isASCII && allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func rfc2822Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    private static func mimeFromExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "gif":          return "image/gif"
        case "webp":         return "image/webp"
        case "svg":          return "image/svg+xml"
        default:             return "image/png"
        }
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
