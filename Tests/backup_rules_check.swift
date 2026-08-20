// Standalone check of the rules fixed during the review pass: the host filter that keeps
// requests off the local network (SSRF), the filename of a .eml archive, and the sender
// read out of non-UTF-8 headers.
//
// No test framework: the project has none, and an XCTest target for three pure functions
// would cost more than the check itself.
//
//   swiftc -O MailKeep/Models/MailFolder.swift MailKeep/Models/Account.swift \
//          MailKeep/Models/EmailMessage.swift MailKeep/Storage/MboxStore.swift \
//          MailKeep/Storage/EmailParser.swift MailKeep/Storage/MessageArchiver.swift \
//          MailKeep/Storage/EmailIndex.swift MailKeep/Views/EmailList/EmailLoader.swift \
//          Tests/backup_rules_check.swift -o /tmp/rulescheck && /tmp/rulescheck

import Foundation

@main
enum BackupRulesCheck {

static var failures = 0

static func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

static func main() {
let account = IMAPAccount(label: "x", host: "h", username: "u")
let base = URL(fileURLWithPath: "/tmp/backup")

print("archiveURL — only the extension goes")
check(MboxStore.archiveURL(baseDir: base, account: account,
                           mboxFilename: "INBOX_2026-08.mbox", offset: 42)
        .lastPathComponent == "INBOX_2026-08_42.eml", "the common case")
// A ".mbox" in the middle of the name belongs to the folder, not to the extension:
// stripping it landed two distinct folders on the same archive file.
check(MboxStore.archiveBaseName("A.mboxB_2026-08.mbox") == "A.mboxB_2026-08", "inner \".mbox\" kept")
check(MboxStore.archiveBaseName("sans_extension") == "sans_extension", "name without an extension")

print("extractSender — the sender survives a non-UTF-8 header")
check(MboxStore.extractSender(from: Data("From: Remy <remy@ex.com>\r\n\r\nbody".utf8)) == "remy@ex.com",
      "UTF-8 header")
let latin1 = "From: R\u{E9}my <remy@ex.com>\r\n\r\nbody".data(using: .isoLatin1)!
check(MboxStore.extractSender(from: latin1) == "remy@ex.com", "ISO-8859-1 header")
check(MboxStore.extractSender(from: Data("Subject: nothing\r\n\r\n".utf8)) == "unknown@unknown",
      "no From header at all")

print("isBlockedHost — the local network stays out of reach")
for host in ["127.0.0.1", "localhost", "10.0.0.5", "192.168.1.1", "172.16.0.1",
             "169.254.169.254", "100.64.0.1", "::1", "0.0.0.0", "machine.local"] {
    check(MessageArchiver.isBlockedHost(host), "blocked: \(host)")
}
// inet_aton accepts far more than the dotted quad — each of these forms reaches
// 127.0.0.1 and walked straight past the filter.
for host in ["2130706433", "0177.0.0.1", "127.1", "0x7f.0.0.1"] {
    check(MessageArchiver.isBlockedHost(host), "disguised form: \(host)")
}
// And public hosts have to keep going through, including those whose name is made of
// nothing but hexadecimal digits and dots.
for host in ["example.com", "8.8.8.8", "93.184.216.34", "cdn.example.org",
             "1e100.net", "abc.def", "ad.ee"] {
    check(!MessageArchiver.isBlockedHost(host), "allowed: \(host)")
}

print("attachment names — a header value never becomes a path")
for (given, expected) in [("../../../../etc/passwd", "passwd"),
                          ("/etc/passwd", "passwd"),
                          ("..\\..\\windows\\system32", "system32"),
                          ("a/b/c.txt", "c.txt"),
                          ("\u{202E}txt.exe", "txt.exe"),      // bidi override stripped
                          ("plain.pdf", "plain.pdf")] {
    let eml = """
    Content-Type: multipart/mixed; boundary="x"\r
    \r
    --x\r
    Content-Type: application/octet-stream\r
    Content-Disposition: attachment; filename="\(given)"\r
    \r
    Zm9v\r
    --x--\r
    """
    let got = EmailParser.parse(data: Data(eml.utf8)).attachments.first?.filename ?? "(none)"
    check(got == expected, "\(given.debugDescription) → \(got.debugDescription)")
}

print("MIME depth — a nested bomb must not take the stack down")
// Each level wraps the previous one; a few thousand of these used to reach the stack
// guard and kill the app with SIGSEGV, mid-backup, before anyone opened the message.
var bomb = "Content-Type: text/plain\r\n\r\nboom\r\n"
for i in 0..<5_000 {
    let b = "b\(i)"
    bomb = "Content-Type: multipart/mixed; boundary=\"\(b)\"\r\n\r\n--\(b)\r\n\(bomb)\r\n--\(b)--\r\n"
}
_ = EmailParser.parse(data: Data(bomb.utf8))
check(true, "5 000 nested multiparts survived")
// And a legitimately nested message still delivers its body.
var deep = "Content-Type: text/plain\r\n\r\ndeep\r\n"
for i in 0..<20 {
    let b = "d\(i)"
    deep = "Content-Type: multipart/mixed; boundary=\"\(b)\"\r\n\r\n--\(b)\r\n\(deep)\r\n--\(b)--\r\n"
}
check(EmailParser.parse(data: Data(deep.utf8)).bodyText?.contains("deep") == true,
      "20 nested levels still reach the body")

print("\nsender token — the mbox \"From \" line needs exactly one token")
// The header line keeps its CR, and `.whitespaces` does not trim it: every "From " line
// the app wrote used to carry one in the middle.
check(MboxStore.extractSender(from: Data("From: a@b.c\r\n\r\nbody".utf8)) == "a@b.c",
      "trailing CR dropped")
// No angle brackets and a display name: the spaces broke the ctime that follows, and the
// restored message lost its INTERNALDATE.
check(MboxStore.extractSender(from: Data("From: Jean Dupont\r\n\r\nbody".utf8)) == "unknown@unknown",
      "display name alone is not a sender")
check(MboxStore.extractSender(from: Data("From: Jean Dupont sales@ex.com\r\n\r\nbody".utf8)) == "sales@ex.com",
      "the address wins over the display name")
// And the whole round trip: the date written into the "From " line has to come back out.
for header in ["From: a@b.c", "From: Jean Dupont", "From: R\u{E9}my <remy@ex.com>", "Subject: none"] {
    let sender = MboxStore.extractSender(from: Data("\(header)\r\n\r\nbody".utf8))
    let line = "From \(sender) \(MboxStore.imapdateToCtime("12-Aug-2026 09:15:00 +0200"))"
    check(MboxStore.ctimeToImapDate(fromMboxFromLine: line) == "12-Aug-2026 07:15:00 +0000",
          "round trip: \(header.debugDescription)")
}

print("\nbase64 — one 8-bit byte must not empty the part")
// `String(data:encoding:.ascii)` returned nil on any byte over 127, so a single stray one
// blanked the body and made the attachment vanish entirely.
var body8 = Data("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\nSGVsbG8gd29ybGQ=".utf8)
body8.append(0xC3)
check(EmailParser.parse(data: body8).bodyText == "Hello world", "body survives")

var att8 = Data("Content-Type: multipart/mixed; boundary=\"x\"\r\n\r\n--x\r\nContent-Type: application/pdf\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"a.pdf\"\r\n\r\nSGVsbG8=".utf8)
att8.append(0xC3)
att8.append(Data("\r\n--x--\r\n".utf8))
check(EmailParser.parse(data: att8).attachments.first?.data == Data("Hello".utf8), "attachment survives")

print("\nMIME breadth — a wide bomb is capped like a deep one")
// maxMIMEDepth bounded how deep the tree went, nothing bounded how wide: 20 000 sibling
// parts in a 1 MB message left 20 000 decoded buffers in memory.
var wide = "Content-Type: multipart/mixed; boundary=\"w\"\r\n\r\n"
for _ in 0..<20_000 {
    wide += "--w\r\nContent-Type: application/octet-stream\r\n\r\nZm9v\r\n"
}
wide += "--w--\r\n"
let wideCount = EmailParser.parse(data: Data(wide.utf8)).attachments.count
check(wideCount <= 200, "20 000 sibling parts capped at \(wideCount)")

print("\nisBlockedHost — a domain is not an IPv6 prefix")
// "fc" and "fd" were matched as prefixes of the host string, so every domain starting
// with those two letters lost its images.
for host in ["fcbank.com", "fdj.fr", "fdn.fr", "fc-barcelona.com", "fe80.example.com"] {
    check(!MessageArchiver.isBlockedHost(host), "allowed: \(host)")
}
// The real IPv6 forms stay out, including the spellings a prefix test never caught.
for host in ["::1", "0:0:0:0:0:0:0:1", "[::1]", "fe80::1", "fe80::1%en0", "fd00::1",
             "fc00::1", "::", "::ffff:127.0.0.1", "::ffff:7f00:1"] {
    check(MessageArchiver.isBlockedHost(host), "blocked: \(host)")
}
check(!MessageArchiver.isBlockedHost("2001:4860:4860::8888"), "allowed: public IPv6")

print("\nindexCovers — a short index sends the folder back through the rebuild")
// UIDs flush every 50 messages, the index every 250. A run cut short leaves messages in
// the mbox that the state counts as downloaded and the index never learned about; the
// fast path trusted any non-empty index and they stayed invisible for good.
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mailkeep-indexcheck-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let mbox = tmp.appendingPathComponent("INBOX_2026-08.mbox")
try? Data(repeating: 0x41, count: 1000).write(to: mbox)
func entry(_ offset: Int64, _ length: Int) -> EmailIndexEntry {
    EmailIndexEntry(id: UUID(), from: "", to: "", cc: "", subject: "", date: nil,
                    filename: "INBOX_2026-08.mbox", offset: offset, length: length)
}
check(EmailLoader.indexCovers([mbox], entries: [entry(0, 500), entry(500, 500)]),
      "an index reaching the last byte is trusted")
check(EmailLoader.indexCovers([mbox], entries: [entry(0, 500), entry(500, 499)]),
      "one byte of slack for a rebuilt index")
check(!EmailLoader.indexCovers([mbox], entries: [entry(0, 500)]),
      "500 bytes of message the index never saw")
check(!EmailLoader.indexCovers([mbox], entries: [entry(0, 500)].map { _ in
        EmailIndexEntry(id: UUID(), from: "", to: "", cc: "", subject: "", date: nil,
                        filename: "OTHER_2026-08.mbox", offset: 0, length: 1000) }),
      "an index that describes another file entirely")

print("\nnormalizeToCRLF — what goes back up the wire is RFC 5322")
// The mbox stores LF; an IMAP APPEND carries a message whose lines end with CRLF.
// Restored messages used to go up with bare LFs, MIME boundaries included.
check(MboxStore.normalizeToCRLF(Data("a\nb\n".utf8)) == Data("a\r\nb\r\n".utf8), "LF becomes CRLF")
check(MboxStore.normalizeToCRLF(Data("a\r\nb\r\n".utf8)) == Data("a\r\nb\r\n".utf8), "CRLF left alone")
check(MboxStore.normalizeToCRLF(Data("a\r\nb\nc\n".utf8)) == Data("a\r\nb\r\nc\r\n".utf8), "mixed endings")
check(MboxStore.normalizeToCRLF(Data("\nx".utf8)) == Data("\r\nx".utf8), "LF in first position")
check(MboxStore.normalizeToCRLF(Data("no newline".utf8)) == Data("no newline".utf8), "nothing to do")
// Idempotent: a second pass must not double the CRs.
let once = MboxStore.normalizeToCRLF(Data("a\nb\n".utf8))
check(MboxStore.normalizeToCRLF(once) == once, "idempotent")
// And the full write → read → wire path, which is what a restore actually does.
let src = Data("From: a@b.c\r\nSubject: x\r\n\r\nligne1\r\nligne2\r\n".utf8)
let mboxFile = tmp.appendingPathComponent("roundtrip.mbox")
if let written = try? MboxStore.appendMessage(messageData: src,
                                              internalDate: "12-Aug-2026 09:15:00 +0200",
                                              sender: MboxStore.extractSender(from: src),
                                              to: mboxFile),
   let back = try? MboxStore.readMessage(at: written.offset, length: written.length, from: mboxFile) {
    check(back.filter { $0 == 0x0D }.isEmpty, "the mbox itself keeps LF endings")
    // The stored block ends with the blank line the mbox format puts between messages.
    check(MboxStore.normalizeToCRLF(back)
            == Data("From: a@b.c\r\nSubject: x\r\n\r\nligne1\r\nligne2\r\n\r\n".utf8),
          "the wire copy gets its CRs back")
} else {
    check(false, "mbox round trip")
}

print(failures == 0 ? "\nAll green." : "\n\(failures) failure(s).")
if failures > 0 { exit(1) }
}
}
