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

print(failures == 0 ? "\nAll green." : "\n\(failures) failure(s).")
if failures > 0 { exit(1) }
}
}
