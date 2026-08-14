// Vérification autonome des règles corrigées lors de la passe de revue :
// le filtre d'hôtes qui protège des requêtes vers le réseau local (SSRF), le nom
// de fichier d'une archive .eml, et l'expéditeur lu dans des en-têtes non-UTF-8.
//
// Sans cadre de test : le projet n'en a pas, et une cible XCTest pour trois
// fonctions pures coûterait plus cher que la vérification elle-même.
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

print("archiveURL — seule l'extension tombe")
check(MboxStore.archiveURL(baseDir: base, account: account,
                           mboxFilename: "INBOX_2026-08.mbox", offset: 42)
        .lastPathComponent == "INBOX_2026-08_42.eml", "cas courant")
// Un « .mbox » au milieu du nom appartient au dossier, pas à l'extension : le retirer
// faisait tomber deux dossiers distincts sur le même fichier d'archive.
check(MboxStore.archiveBaseName("A.mboxB_2026-08.mbox") == "A.mboxB_2026-08", "« .mbox » interne conservé")
check(MboxStore.archiveBaseName("sans_extension") == "sans_extension", "nom sans extension")

print("extractSender — l'expéditeur survit à un en-tête non-UTF-8")
check(MboxStore.extractSender(from: Data("From: Remy <remy@ex.com>\r\n\r\ncorps".utf8)) == "remy@ex.com",
      "en-tête UTF-8")
let latin1 = "From: R\u{E9}my <remy@ex.com>\r\n\r\ncorps".data(using: .isoLatin1)!
check(MboxStore.extractSender(from: latin1) == "remy@ex.com", "en-tête ISO-8859-1")
check(MboxStore.extractSender(from: Data("Subject: rien\r\n\r\n".utf8)) == "unknown@unknown",
      "aucun en-tête From")

print("isBlockedHost — le réseau local reste hors d'atteinte")
for host in ["127.0.0.1", "localhost", "10.0.0.5", "192.168.1.1", "172.16.0.1",
             "169.254.169.254", "100.64.0.1", "::1", "0.0.0.0", "machine.local"] {
    check(MessageArchiver.isBlockedHost(host), "bloqué : \(host)")
}
// inet_aton accepte bien plus que le quadruplet pointé — chacune de ces formes
// atteint 127.0.0.1 et passait au travers du filtre.
for host in ["2130706433", "0177.0.0.1", "127.1", "0x7f.0.0.1"] {
    check(MessageArchiver.isBlockedHost(host), "forme détournée : \(host)")
}
// Et les hôtes publics doivent continuer à passer, y compris ceux dont le nom
// n'est composé que de chiffres hexadécimaux et de points.
for host in ["example.com", "8.8.8.8", "93.184.216.34", "cdn.example.org",
             "1e100.net", "abc.def", "ad.ee"] {
    check(!MessageArchiver.isBlockedHost(host), "autorisé : \(host)")
}

print(failures == 0 ? "\nTout est vert." : "\n\(failures) échec(s).")
if failures > 0 { exit(1) }
}
}
