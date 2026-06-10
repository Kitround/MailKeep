import Foundation

struct EmailAttachment: Identifiable {
    let id = UUID()
    let filename: String   // ex. "rapport.pdf"
    let mimeType: String   // ex. "application/pdf"
    let data: Data         // décodé (base64/QP résolu)

    var size: Int { data.count }

    var sfSymbol: String {
        let m = mimeType.lowercased()
        if m.hasPrefix("image/")       { return "photo.fill" }
        if m.hasPrefix("audio/")       { return "music.note" }
        if m.hasPrefix("video/")       { return "video.fill" }
        if m.contains("pdf")           { return "doc.richtext.fill" }
        if m.contains("zip") || m.contains("archive") || m.contains("gzip") || m.contains("tar") {
            return "archivebox.fill"
        }
        if m.hasPrefix("text/")        { return "doc.text.fill" }
        if m.contains("spreadsheet") || m.contains("excel") || m.contains("csv") {
            return "tablecells.fill"
        }
        if m.contains("presentation") || m.contains("powerpoint") {
            return "rectangle.on.rectangle.fill"
        }
        if m.contains("word") || m.contains("document") { return "doc.fill" }
        return "paperclip"
    }

    var formattedSize: String {
        let kb = Double(size) / 1_000
        let mb = kb / 1_000
        if mb >= 1  { return String(format: "%.1f Mo", mb) }
        if kb >= 1  { return String(format: "%.0f Ko", kb) }
        return "\(size) o"
    }
}

struct EmailMessage: Identifiable {
    var id: UUID = UUID()
    var from: String = ""
    var to: String = ""
    var cc: String = ""
    var subject: String = "(Sans sujet)"
    var date: Date? = nil
    var bodyText: String? = nil
    var bodyHTML: String? = nil
    var hasAttachments: Bool = false   // set from index — true même avant chargement du corps
    var attachments: [EmailAttachment] = []
    // File location for lazy body loading (set for index-loaded messages)
    var mboxFileURL: URL? = nil
    var mboxOffset: Int64 = 0
    var mboxLength: Int = 0
    // Raw data kept only during streaming fallback
    var rawData: Data? = nil

    var displaySender: String {
        let s = from.trimmingCharacters(in: .whitespaces)
        if let ltIdx = s.lastIndex(of: "<") {
            let name = String(s[..<ltIdx]).trimmingCharacters(in: .init(charactersIn: "\" "))
            return name.isEmpty ? s : name
        }
        return s
    }

    var preview: String {
        let body = bodyText ?? ""
        return body
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(120)
            .description
    }
}
