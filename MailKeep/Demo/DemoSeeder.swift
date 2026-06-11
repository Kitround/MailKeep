import Foundation

#if DEBUG
/// Seeds the app with a fake account, mbox file and history so a single
/// launch produces a clean, screenshot-ready state.
/// Activate by passing `--demo` as a launch argument (Xcode → Edit Scheme
/// → Run → Arguments → "Arguments passed on launch").
/// Debug builds only — never compiled into releases.
enum DemoSeeder {

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo")
    }

    @MainActor
    static func seed(into state: AppState) {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MailKeepDemo", isDirectory: true)
        // Reset any leftovers from a previous demo run.
        try? FileManager.default.removeItem(at: baseURL)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        var account = IMAPAccount(
            label: "Demo Workspace",
            host: "imap.example.com",
            username: "alex.morgan@example.com"
        )
        var sent = MailFolder(name: "Sent")
        sent.isEnabled = false
        account.folders = [
            MailFolder(name: "INBOX"),
            MailFolder(name: "Archive"),
            sent,
        ]
        account.messageFilter = .all

        let inbox = account.folders[0]
        writeMessages(sampleMessages, account: account, folder: inbox, baseURL: baseURL)

        state.backupBaseURL = baseURL
        state.accounts = [account]
        state.selectedAccountID = account.id
        state.selectedFolderID = inbox.id
        state.backupRuns = sampleRuns(for: account)
    }

    // MARK: - Mbox + index writer

    private static func writeMessages(
        _ messages: [DemoMessage],
        account: IMAPAccount,
        folder: MailFolder,
        baseURL: URL
    ) {
        let mboxURL = MboxStore.mboxURL(
            baseDir: baseURL, account: account,
            folderName: folder.name,
            year: Calendar.current.component(.year, from: Date()),
            month: Calendar.current.component(.month, from: Date())
        )

        var entries: [EmailIndexEntry] = []
        for msg in messages {
            let data = msg.rfc822Data
            let sender = MboxStore.extractSender(from: data)
            let internalDate = MboxStore.imapDate(from: msg.date)
            guard let written = try? MboxStore.appendMessage(
                messageData: data,
                internalDate: internalDate,
                sender: sender,
                to: mboxURL
            ) else { continue }

            entries.append(EmailIndexEntry(
                id: UUID(),
                from: msg.from,
                to: msg.to,
                cc: "",
                subject: msg.subject,
                date: msg.date,
                filename: mboxURL.lastPathComponent,
                offset: written.offset,
                length: written.length,
                hasAttachments: msg.hasAttachment
            ))
        }

        let idxURL = MboxStore.indexURL(baseDir: baseURL, account: account, folderName: folder.name)
        try? EmailIndexStore(indexURL: idxURL).save(entries)
    }

    // MARK: - Sample data

    private static var sampleMessages: [DemoMessage] {
        let now = Date()
        let cal = Calendar.current
        func ago(_ component: Calendar.Component, _ value: Int) -> Date {
            cal.date(byAdding: component, value: -value, to: now) ?? now
        }

        return [
            DemoMessage(
                from: "Sarah Chen <sarah.chen@northwind.io>",
                to: "Alex Morgan <alex.morgan@example.com>",
                subject: "Welcome to the team!",
                date: ago(.hour, 2),
                body: """
                Hi Alex,

                Really excited to have you onboard. Let me know when you have a
                free slot for a quick intro this week — I'll walk you through
                how we work and introduce you to the rest of the team.

                Welcome aboard!
                Sarah
                """,
                hasAttachment: false
            ),
            DemoMessage(
                from: "GitHub <noreply@github.com>",
                to: "Alex Morgan <alex.morgan@example.com>",
                subject: "[Kitround/MailKeep] PR #42: Add per-account message filter",
                date: ago(.hour, 5),
                body: """
                A new pull request was opened on a repository you watch.

                #42 Add per-account message filter
                Opened by kitround.

                View on GitHub:
                https://github.com/Kitround/MailKeep/pull/42
                """,
                hasAttachment: false
            ),
            DemoMessage(
                from: "Lina Park <lina.park@stripe.com>",
                to: "Alex Morgan <alex.morgan@example.com>",
                subject: "Invoice INV-2026-08 — March services",
                date: ago(.day, 1),
                body: """
                Hi Alex,

                Please find attached the invoice for services rendered in March.
                Net 30 as agreed. Let me know if you need anything else.

                Best,
                Lina
                """,
                hasAttachment: true
            ),
            DemoMessage(
                from: "Anders Bjørn <anders@northwind.io>",
                to: "Alex Morgan <alex.morgan@example.com>",
                subject: "Re: Quarterly review — notes from yesterday",
                date: ago(.day, 2),
                body: """
                Quick recap of what we agreed on:

                  • Ship 1.5 by end of month
                  • Postpone the localization rework to Q3
                  • Schedule a working session on the new backup format

                Happy to dig deeper on any of these.
                — Anders
                """,
                hasAttachment: false
            ),
            DemoMessage(
                from: "AWS Billing <billing@amazon.com>",
                to: "Alex Morgan <alex.morgan@example.com>",
                subject: "Your March invoice is ready",
                date: ago(.day, 5),
                body: """
                Your AWS invoice for March is now available.

                Total due: $148.27
                Due date: April 15

                Sign in to the AWS Billing console to download a copy.
                """,
                hasAttachment: false
            ),
            DemoMessage(
                from: "Maya Singh <maya@designhouse.studio>",
                to: "Alex Morgan <alex.morgan@example.com>",
                subject: "Updated mockups for review",
                date: ago(.day, 7),
                body: """
                Hi Alex,

                Second pass on the dashboard mockups attached. I addressed the
                feedback from Friday — sidebar now collapses cleanly and the
                empty states feel a lot less awkward.

                Looking forward to your thoughts.
                Maya
                """,
                hasAttachment: true
            ),
            DemoMessage(
                from: "Calendly <notifications@calendly.com>",
                to: "Alex Morgan <alex.morgan@example.com>",
                subject: "New meeting: Pierre Dubois — Friday 3:00 PM",
                date: ago(.day, 9),
                body: """
                A new meeting has been scheduled.

                With:  Pierre Dubois
                When:  Friday, 3:00 PM – 3:30 PM (Europe/Paris)
                Where: Google Meet (link included in the calendar invite)
                """,
                hasAttachment: false
            ),
            DemoMessage(
                from: "Mom <m.morgan@example.com>",
                to: "Alex Morgan <alex.morgan@example.com>",
                subject: "Family dinner on Sunday?",
                date: ago(.day, 14),
                body: """
                Sweetheart,

                We were thinking of doing a family dinner this Sunday at the
                house. Your sister is in town. Around 7 work for you?

                Love,
                Mom
                """,
                hasAttachment: false
            ),
        ]
    }

    private static func sampleRuns(for account: IMAPAccount) -> [BackupRun] {
        let now = Date()
        let cal = Calendar.current
        func ago(_ days: Int, _ hours: Int = 0) -> Date {
            cal.date(byAdding: .second, value: -(days * 86400 + hours * 3600), to: now) ?? now
        }

        func run(folder: String, daysAgo: Int, downloaded: Int, skipped: Int, bytes: Int64,
                 stopped: Bool = false, failed: String? = nil) -> BackupRun {
            var r = BackupRun(
                accountID: account.id,
                accountLabel: account.label,
                folderName: folder,
                startedAt: ago(daysAgo)
            )
            r.finishedAt = ago(daysAgo, -1)
            r.messagesDownloaded = downloaded
            r.messagesSkipped = skipped
            r.bytesWritten = bytes
            r.wasStopped = stopped
            r.errorMessage = failed
            return r
        }

        return [
            run(folder: "INBOX",   daysAgo: 0, downloaded: 8,   skipped: 4218, bytes:    862_140),
            run(folder: "Archive", daysAgo: 0, downloaded: 0,   skipped: 12903, bytes:         0),
            run(folder: "INBOX",   daysAgo: 1, downloaded: 24,  skipped: 4194, bytes:  3_127_004),
            run(folder: "Archive", daysAgo: 1, downloaded: 3,   skipped: 12900, bytes:    412_022),
            run(folder: "INBOX",   daysAgo: 2, downloaded: 17,  skipped: 4177, bytes:  1_945_318, stopped: true),
            run(folder: "INBOX",   daysAgo: 3, downloaded: 41,  skipped: 4136, bytes:  5_881_445),
            run(folder: "Archive", daysAgo: 3, downloaded: 162, skipped: 12738, bytes: 22_402_119),
        ]
    }
}

// MARK: - Demo message → RFC822

private struct DemoMessage {
    let from: String
    let to: String
    let subject: String
    let date: Date
    let body: String
    let hasAttachment: Bool

    var rfc822Data: Data {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var headers = ""
        headers += "Date: \(df.string(from: date))\r\n"
        headers += "From: \(from)\r\n"
        headers += "To: \(to)\r\n"
        headers += "Subject: \(subject)\r\n"
        headers += "Message-ID: <\(UUID().uuidString)@demo.mailkeep>\r\n"
        headers += "MIME-Version: 1.0\r\n"

        if hasAttachment {
            let boundary = "----=_DemoBoundary_\(UUID().uuidString.prefix(12))"
            headers += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n"
            let attachmentBytes = Data("Demo attachment payload — not a real file.".utf8).base64EncodedString()
            let combined = """
            \(headers)\r
            --\(boundary)\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            \(body)\r
            --\(boundary)\r
            Content-Type: application/octet-stream; name="attachment.txt"\r
            Content-Disposition: attachment; filename="attachment.txt"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(attachmentBytes)\r
            --\(boundary)--\r
            """
            return Data(combined.utf8)
        }

        headers += "Content-Type: text/plain; charset=utf-8\r\n"
        return Data("\(headers)\r\n\(body)\r\n".utf8)
    }
}
#endif
