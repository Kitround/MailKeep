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

        // Collect remote candidates in document order, capped.
        var candidates: [(range: NSRange, src: String)] = []
        for match in matches {
            guard match.numberOfRanges == 2 else { continue }
            let src = ns.substring(with: match.range(at: 1))
            let lower = src.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }
            candidates.append((match.range(at: 1), src))
            if candidates.count >= maxImages { break }
        }
        guard !candidates.isEmpty else { return (html, []) }

        // Fetch them in parallel — previously serial, which stacked timeouts.
        // fetch returns (data, mime).
        var byIndex: [Int: (data: Data, mime: String)] = [:]
        await withTaskGroup(of: (Int, (Data, String)?).self) { group in
            for (i, c) in candidates.enumerated() {
                group.addTask { (i, await fetch(c.src)) }
            }
            for await (i, res) in group {
                if let res { byIndex[i] = (res.0, res.1) }
            }
        }

        // Assign Content-IDs in document order, enforce the total cap, then splice
        // replacements back-to-front so earlier NSRanges stay valid.
        var fetched: [(String, String, Data)] = []
        var splices: [(NSRange, String)] = []
        var totalBytes = 0
        for (i, c) in candidates.enumerated() {
            guard let img = byIndex[i] else { continue }
            guard img.data.count <= maxBytesPerImage, totalBytes + img.data.count <= maxTotalBytes else { continue }
            totalBytes += img.data.count
            let cid = "mkimg\(fetched.count)@mailkeep"
            fetched.append((cid, img.mime, img.data))
            splices.append((c.range, "cid:\(cid)"))
        }

        var result = html
        for (range, replacement) in splices.sorted(by: { $0.0.location > $1.0.location }) {
            if let r = Range(range, in: result) { result.replaceSubrange(r, with: replacement) }
        }
        return (result, fetched)
    }

    private static func fetch(_ urlString: String) async -> (Data, String)? {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !isBlockedHost(host) else { return nil }

        var req = URLRequest(url: url)
        // Browser-ish headers — many CDNs 404 plain requests (e.g. S3 NoSuchKey).
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("image/avif,image/webp,image/png,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        // ImageFetcher enforces 2xx, caps the body size during download, and blocks
        // redirects to private/loopback hosts (SSRF defense).
        guard let data = await ImageFetcher(maxBytes: maxBytesPerImage, timeout: fetchTimeout).run(req),
              !data.isEmpty, let sniffed = sniffImageMime(data) else { return nil }
        return (data, sniffed)
    }

    /// Blocks loopback, link-local, private and CGNAT address literals plus obvious
    /// local hostnames — prevents an attacker email from making the app probe the LAN
    /// or localhost services via `<img src>`. (Domain → private-IP rebinding is not
    /// fully covered without resolving; the redirect check narrows that window.)
    static func isBlockedHost(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") { h.removeFirst() }      // strip IPv6 brackets
        if h.hasSuffix("]") { h.removeLast() }
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".localhost") {
            return true
        }
        // IPv6 loopback / link-local / unique-local
        if h == "::1" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("::ffff:") {
            return true
        }
        // IPv4 literal, in whatever form. `inet_aton` — the same parser the network
        // stack uses — accepts far more than dotted-quad: "2130706433", "0177.0.0.1"
        // and "127.1" all reach 127.0.0.1, and each one walked straight past a
        // dotted-quad-only check.
        if let octets = ipv4Octets(h) {
            let a = octets[0], b = octets[1]
            if a == 0 || a == 10 || a == 127 { return true }
            if a == 169 && b == 254 { return true }            // link-local + cloud metadata
            if a == 172 && (16...31).contains(b) { return true }
            if a == 192 && b == 168 { return true }
            if a == 100 && (64...127).contains(b) { return true } // CGNAT
        }
        return false
    }

    /// The four bytes of an IPv4 literal, or nil when the host is not one at all.
    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        // Reject anything with a non-address character up front: inet_aton stops at the
        // first invalid byte, so "127.0.0.1.example.com" would otherwise read as loopback.
        guard !host.isEmpty,
              host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X" }) else { return nil }
        var addr = in_addr()
        guard inet_aton(host, &addr) != 0 else { return nil }
        let raw = UInt32(bigEndian: addr.s_addr)
        return [UInt8(raw >> 24 & 0xFF), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
    }

    /// Identifies an image strictly from its leading magic bytes.
    private static func sniffImageMime(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 4, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "image/gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "image/bmp" }
        return nil
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
        // Identité d'origine conservée : sans elle, réimporter l'archive crée un doublon
        // du mail et le détache de son fil de discussion.
        headers += "Message-ID: \(headerToken(message.messageID) ?? "<\(UUID().uuidString)@mailkeep>")\r\n"
        if let inReplyTo = headerToken(message.inReplyTo) { headers += "In-Reply-To: \(inReplyTo)\r\n" }
        if let references = headerToken(message.references) { headers += "References: \(references)\r\n" }
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

    /// Valeur d'en-tête reprise telle quelle (Message-ID, In-Reply-To, References) :
    /// vidée des retours à la ligne, qui permettraient d'injecter d'autres en-têtes.
    private static func headerToken(_ value: String?) -> String? {
        guard let raw = value else { return nil }
        let clean = raw.replacingOccurrences(of: "\r", with: "")
                       .replacingOccurrences(of: "\n", with: " ")
                       .trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
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

    /// Alloué une fois : `DateFormatter` coûte cher et l'archivage en crée un par message.
    /// Jamais muté après construction, donc lisible depuis plusieurs tâches à la fois.
    private static let rfc2822Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private static func rfc2822Date(_ date: Date) -> String {
        rfc2822Formatter.string(from: date)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// One-shot image download with hard limits: 2xx only, body size capped *during*
/// streaming (a hostile URL can't buffer gigabytes), and redirects to private/loopback
/// hosts refused (SSRF defense). One instance per request.
private final class ImageFetcher: NSObject, URLSessionDataDelegate {
    private let maxBytes: Int
    private let timeout: TimeInterval
    private var buffer = Data()
    private var headerOK = false
    private var continuation: CheckedContinuation<Data?, Never>?
    private var settled = false

    init(maxBytes: Int, timeout: TimeInterval) {
        self.maxBytes = maxBytes
        self.timeout = timeout
    }

    func run(_ request: URLRequest) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            continuation = cont
            session.dataTask(with: request).resume()
        }
    }

    private func settle(_ result: Data?) {
        guard !settled, let cont = continuation else { return }
        settled = true
        continuation = nil
        cont.resume(returning: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= Int64(maxBytes) else {
            completionHandler(.cancel); settle(nil); return
        }
        headerOK = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if buffer.count > maxBytes { dataTask.cancel(); settle(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let host = request.url?.host, !MessageArchiver.isBlockedHost(host),
           let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            completionHandler(request)
        } else {
            completionHandler(nil)   // refuse redirect to a private/non-http target
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        settle(error == nil && headerOK ? buffer : nil)
    }
}
