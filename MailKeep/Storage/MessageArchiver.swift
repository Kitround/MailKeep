import Foundation

/// Builds a self-contained .html archive of a message: HTML body with every image
/// (inline cid: and remote http/https) inlined as a data: URI, plus attachments
/// embedded as download links. Opt-in per account — fetching remote images makes
/// HTTP requests to sender servers.
enum MessageArchiver {

    // Safety caps — a hostile message must not exhaust memory or stall a backup.
    private static let maxImages = 40
    private static let maxBytesPerImage = 15 * 1024 * 1024
    private static let maxTotalBytes = 80 * 1024 * 1024
    private static let fetchTimeout: TimeInterval = 12

    /// Parses the raw message, inlines images, writes the archive. Best-effort:
    /// individual image fetch failures leave the original URL untouched.
    static func archive(rfc822: Data, to url: URL) async {
        let message = await Task.detached { EmailParser.parse(data: rfc822) }.value

        let bodyHTML: String
        if let html = message.bodyHTML, !html.isEmpty {
            bodyHTML = html
        } else {
            bodyHTML = "<pre>\(escapeHTML(message.bodyText ?? ""))</pre>"
        }

        let inlined = await inlineImages(in: bodyHTML, attachments: message.attachments)
        let document = wrap(body: inlined, attachments: message.attachments)

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(document.utf8).write(to: url, options: .atomic)
        } catch {
            // Archiving is best-effort — never fail the backup over it.
        }
    }

    // MARK: - Image inlining

    private static func inlineImages(in html: String, attachments: [EmailAttachment]) async -> String {
        let pattern = #"src\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var result = html
        var imageCount = 0
        var totalBytes = 0

        // Reverse so earlier ranges stay valid while we splice replacements in.
        for match in matches.reversed() {
            guard match.numberOfRanges == 2 else { continue }
            let src = ns.substring(with: match.range(at: 1))
            let lower = src.lowercased()
            if lower.hasPrefix("data:") { continue }
            guard imageCount < maxImages else { continue }

            var dataURI: String? = nil

            if lower.hasPrefix("cid:") {
                let cid = String(src.dropFirst(4)).trimmingCharacters(in: .init(charactersIn: "<> "))
                if let att = attachments.first(where: { $0.contentID == cid }) {
                    dataURI = makeDataURI(mime: att.mimeType, data: att.data)
                }
            } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                if let (data, mime) = await fetch(src), data.count <= maxBytesPerImage,
                   totalBytes + data.count <= maxTotalBytes {
                    totalBytes += data.count
                    dataURI = makeDataURI(mime: mime, data: data)
                }
            }

            guard let uri = dataURI else { continue }
            // Replace just the captured URL, keeping the surrounding src="…" intact.
            if let full = Range(match.range(at: 1), in: result) {
                result.replaceSubrange(full, with: uri)
                imageCount += 1
            }
        }
        return result
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

    // MARK: - Document assembly

    private static func wrap(body: String, attachments: [EmailAttachment]) -> String {
        // Only list real attachments (not inline images already shown in the body).
        let files = attachments.filter { !$0.isInline && $0.contentID == nil }
        var section = ""
        if !files.isEmpty {
            var links = ""
            for att in files {
                let uri = makeDataURI(mime: att.mimeType, data: att.data)
                links += """
                <li><a href="\(uri)" download="\(escapeHTML(att.filename))">\(escapeHTML(att.filename))</a> \
                <span class="sz">(\(att.formattedSize))</span></li>
                """
            }
            section = """
            <div class="mk-attachments">
              <div class="mk-title">Pièces jointes</div>
              <ul>\(links)</ul>
            </div>
            """
        }

        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="UTF-8">
        <meta name="color-scheme" content="light dark">
        <style>
          body { font-family: -apple-system, sans-serif; font-size: 14px; margin: 16px;
                 line-height: 1.5; word-wrap: break-word; }
          img { max-width: 100%; height: auto; }
          .mk-attachments { margin-top: 24px; padding-top: 12px; border-top: 1px solid #8884; }
          .mk-title { font-weight: 600; margin-bottom: 6px; }
          .mk-attachments ul { margin: 0; padding-left: 18px; }
          .sz { color: #8888; font-size: 12px; }
        </style>
        </head><body>
        \(body)
        \(section)
        </body></html>
        """
    }

    // MARK: - Helpers

    private static func makeDataURI(mime: String, data: Data) -> String {
        let type = mime.isEmpty ? "application/octet-stream" : mime
        return "data:\(type);base64,\(data.base64EncodedString())"
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
