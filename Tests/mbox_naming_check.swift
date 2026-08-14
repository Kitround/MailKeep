// Standalone check of the mbox naming rules — the ones that decide which files a folder
// owns (so which it displays and which it deletes) and which monthly file a message is
// filed into.
//
// No test framework: the project has none, and an XCTest target for two pure functions
// would cost more than the check itself.
//
//   swiftc -O MailKeep/Models/MailFolder.swift MailKeep/Models/Account.swift \
//          MailKeep/Storage/MboxStore.swift Tests/mbox_naming_check.swift \
//          -o /tmp/mboxcheck && /tmp/mboxcheck

import Foundation

@main
enum MboxNamingCheck {

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
print("isMbox — a folder owns only ITS OWN files")
check(MboxStore.isMbox("INBOX_2026-08.mbox", ofFolder: "INBOX"), "the folder's own period")
check(MboxStore.isMbox("INBOX_imported_20260806_143012.mbox", ofFolder: "INBOX"), "import")
check(MboxStore.isMbox("INBOX_imported_20260806_143012_2.mbox", ofFolder: "INBOX"), "multiple import")
check(MboxStore.isMbox("INBOX_Travail_2026-08.mbox", ofFolder: "INBOX_Travail"), "subfolder matching itself")
// The two regressions that wiped neighbouring backups:
check(!MboxStore.isMbox("INBOX_Travail_2026-08.mbox", ofFolder: "INBOX"), "subfolder NOT caught by its parent")
check(!MboxStore.isMbox("INBOXOLD_2026-08.mbox", ofFolder: "INBOX"), "neighbouring folder NOT caught")
check(!MboxStore.isMbox("INBOX_index.json", ofFolder: "INBOX"), "index ignored")
check(!MboxStore.isMbox("INBOX_2026-8.mbox", ofFolder: "INBOX"), "malformed period rejected")

print("isArchive — same rules for .eml files")
check(MboxStore.isArchive("INBOX_2026-08_4096.eml", ofFolder: "INBOX"), "the folder's archive")
check(MboxStore.isArchive("INBOX_imported_20260806_143012_4096.eml", ofFolder: "INBOX"), "an import's archive")
check(!MboxStore.isArchive("INBOX_Travail_2026-08_4096.eml", ofFolder: "INBOX"), "a subfolder's archive spared")
check(!MboxStore.isArchive("INBOX_2026-08.mbox", ofFolder: "INBOX"), "an mbox is not an archive")

print("yearMonth — the month is the one in the message's time zone")
check(MboxStore.yearMonth(fromInternalDate: "1-Aug-2026 00:30:00 +0200") == (2026, 8), "1 Aug 00:30 +0200 → August")
check(MboxStore.yearMonth(fromInternalDate: "31-Jul-2026 23:30:00 -0300") == (2026, 7), "31 Jul 23:30 -0300 → July")
check(MboxStore.yearMonth(fromInternalDate: "31-Dec-2025 23:00:00 +0100") == (2025, 12), "New Year's Eve → December")

print(failures == 0 ? "\nAll green." : "\n\(failures) failure(s).")
exit(failures == 0 ? 0 : 1)
}
}
