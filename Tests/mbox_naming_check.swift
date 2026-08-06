// Vérification autonome des règles de nommage mbox — celles qui décident quels
// fichiers un dossier possède (donc lesquels il affiche et lesquels il supprime)
// et dans quel fichier mensuel un message est classé.
//
// Sans cadre de test : le projet n'en a pas, et une cible XCTest pour deux
// fonctions pures coûterait plus cher que la vérification elle-même.
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
print("isMbox — un dossier ne possède que SES fichiers")
check(MboxStore.isMbox("INBOX_2026-08.mbox", ofFolder: "INBOX"), "période du dossier")
check(MboxStore.isMbox("INBOX_imported_20260806_143012.mbox", ofFolder: "INBOX"), "import")
check(MboxStore.isMbox("INBOX_imported_20260806_143012_2.mbox", ofFolder: "INBOX"), "import multiple")
check(MboxStore.isMbox("INBOX_Travail_2026-08.mbox", ofFolder: "INBOX_Travail"), "sous-dossier pour lui-même")
// Les deux régressions qui effaçaient les sauvegardes voisines :
check(!MboxStore.isMbox("INBOX_Travail_2026-08.mbox", ofFolder: "INBOX"), "sous-dossier NON capté par le parent")
check(!MboxStore.isMbox("INBOXOLD_2026-08.mbox", ofFolder: "INBOX"), "dossier voisin NON capté")
check(!MboxStore.isMbox("INBOX_index.json", ofFolder: "INBOX"), "index ignoré")
check(!MboxStore.isMbox("INBOX_2026-8.mbox", ofFolder: "INBOX"), "période mal formée rejetée")

print("isArchive — mêmes règles pour les .eml")
check(MboxStore.isArchive("INBOX_2026-08_4096.eml", ofFolder: "INBOX"), "archive du dossier")
check(MboxStore.isArchive("INBOX_imported_20260806_143012_4096.eml", ofFolder: "INBOX"), "archive d'un import")
check(!MboxStore.isArchive("INBOX_Travail_2026-08_4096.eml", ofFolder: "INBOX"), "archive d'un sous-dossier épargnée")
check(!MboxStore.isArchive("INBOX_2026-08.mbox", ofFolder: "INBOX"), "mbox n'est pas une archive")

print("yearMonth — le mois est celui du fuseau du message")
check(MboxStore.yearMonth(fromInternalDate: "1-Aug-2026 00:30:00 +0200") == (2026, 8), "1er août 00:30 +0200 → août")
check(MboxStore.yearMonth(fromInternalDate: "31-Jul-2026 23:30:00 -0300") == (2026, 7), "31 juil. 23:30 -0300 → juillet")
check(MboxStore.yearMonth(fromInternalDate: "31-Dec-2025 23:00:00 +0100") == (2025, 12), "réveillon → décembre")

print(failures == 0 ? "\nTout est vert." : "\n\(failures) échec(s).")
exit(failures == 0 ? 0 : 1)
}
}
