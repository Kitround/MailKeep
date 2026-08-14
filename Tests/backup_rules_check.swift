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

print(failures == 0 ? "\nAll green." : "\n\(failures) failure(s).")
if failures > 0 { exit(1) }
}
}
