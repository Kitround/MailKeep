# MailKeep — Context

## Overview
macOS SwiftUI app for **IMAP email backup/restore** to `.mbox` format.
Direct connection to IMAP servers over TLS (port 993), no dependency on Mail.app.
Architecture: `@MainActor` + `actor` Swift Concurrency, no CoreData.

---

## File Structure

```
MailKeep/
├── Demo/
│   └── DemoSeeder.swift         — Fake account + emails for screenshots (--demo flag, DEBUG only)
├── Engine/
│   ├── BackupEngine.swift       — Main orchestrator (backup, restore, import, stop)
│   └── SchedulerService.swift   — Automatic scheduled backup triggering
├── IMAP/
│   ├── IMAPClient.swift         — Low-level IMAP client (actor, TLS via NWConnection)
│   ├── IMAPError.swift          — IMAP error enum
│   ├── IMAPParser.swift         — IMAP response parsing (lines, literals, UIDs...)
│   └── IMAPResponse.swift       — Response types (IMAPResponseLine, CollectedResponse, FolderStatus, FetchedMessage)
├── Models/
│   ├── Account.swift            — IMAPAccount (id, host, port, username, label, folders, schedule)
│   ├── AppState.swift           — @MainActor ObservableObject, single source of truth
│   ├── BackupRecord.swift       — BackupRun + BackupProgress (phases, counters, errors)
│   ├── EmailMessage.swift       — EmailMessage (parsed headers, mbox offset, attachments)
│   └── MailFolder.swift         — MailFolder (id, name, displayName, isEnabled)
├── Storage/
│   ├── EmailIndex.swift         — EmailIndexEntry + EmailIndexStore (JSON message index)
│   ├── EmailParser.swift        — RFC822 parsing (headers, MIME, attachments)
│   ├── KeychainStore.swift      — Secure IMAP password storage
│   ├── MboxStore.swift          — .mbox file read/write (Unix mbox format)
│   └── StateStore.swift         — JSON persistence of saved UIDs + uidValidity/uidNext
├── Views/
│   ├── Detail/
│   │   ├── DetailView.swift             — Right panel (selected folder content)
│   │   ├── ProgressDetailView.swift     — In-progress backup display
│   │   ├── RestoreMessageView.swift     — Single message restore confirmation
│   │   └── RestoreView.swift            — Full folder restore from .mbox
│   ├── EmailDetail/
│   │   ├── EmailDetailView.swift        — Email display (headers + body)
│   │   └── WebView.swift                — WKWebView for HTML email rendering
│   ├── EmailList/
│   │   ├── EmailListView.swift          — Email list for a backed-up folder
│   │   ├── EmailLoader.swift            — Lazy email loading from index + mbox
│   │   └── EmailRowView.swift           — Email row cell
│   ├── History/
│   │   ├── BackupHistoryView.swift      — Backup run history
│   │   └── BackupRunRowView.swift       — Single run row
│   ├── MenuBar/
│   │   └── MenuBarView.swift            — Menu bar icon + status popover
│   ├── Settings/
│   │   ├── AccountSettingsView.swift    — IMAP account config (host, port, user, password)
│   │   ├── AppSettingsView.swift        — Global preferences (backup folder, frequency...)
│   │   └── FolderPickerView.swift       — IMAP folder selection for backup
│   └── Sidebar/
│       ├── AccountRowView.swift         — Account row in sidebar
│       ├── FolderRowView.swift          — Folder row in sidebar
│       └── SidebarView.swift            — Main sidebar (accounts > folders)
└── ContentView.swift            — Root layout (sidebar + detail)
```

---

## Data Flow

```
AppState (source of truth)
  ├── [IMAPAccount]  →  KeychainStore (passwords)
  ├── [BackupRun]    →  persisted to disk (JSON)
  └── activeProgress: [UUID: BackupProgress]  →  displayed in ProgressDetailView

BackupEngine (@MainActor)
  └── IMAPClient (actor, 30 s receive watchdog)
        ├── NWConnection (TLS/993)
        ├── UID SEARCH <filter>    ← per-account MessageFilter (ALL/SEEN/UNSEEN/FLAGGED, default SEEN)
        ├── UID FETCH + BODY.PEEK[] ← never sets the \Seen flag
        └── APPEND                 ← restore to IMAP server (INTERNALDATE preserved)

Storage pipeline (backup)
  MboxStore.appendMessage() → .mbox file (one per year/month, byte-preserving)
  EmailIndexStore.save()    → JSON index (kept in memory during a run, flushed every 250 msgs)
  StateStore.addUIDs()      → UIDs + uidValidity persisted
```

---

## Incremental Backup Logic

1. Load `FolderState` from `StateStore` (already-saved UIDs + `uidValidity`)
2. If `uidValidity` changed → full state reset (UIDs are no longer valid)
3. `UID SEARCH <filter>` (per-account `MessageFilter`) → full UID list matching the filter
4. Filter out UIDs already in `knownUIDs` → only new messages are downloaded
5. Download with `fetchWithRetry` (3 attempts, auto-reconnect)
6. Flush UIDs to `StateStore` every 50 messages; JSON index every 250 (kept in memory during the run)
7. If stop requested: partial save → resumes where it left off on next run

---

## Persistence Files (on disk)

| File | Content |
|---|---|
| `~/Library/.../backup/<account>/<folder>_YYYY_MM.mbox` | Messages in Unix mbox format |
| `~/Library/.../<account>/<folder>_index.json` | EmailIndexEntry index (offset, headers) |
| `~/Library/.../state/<accountID>/<folder>.json` | Saved UIDs + uidValidity |
| Keychain | IMAP password per account |

---

## Key Implementation Notes

- **`BODY.PEEK[]`** used in `fetchMessage` → never sets the `\Seen` flag on the server
- **`MessageFilter`** per account (ALL/SEEN/UNSEEN/FLAGGED) drives `UID SEARCH`; default SEEN for backwards compat
- **`IMAPClient`** is a Swift `actor` → thread-safe, no manual locking; every receive is raced against a 30 s watchdog that cancels the connection on stall
- **`receiveBuffer`** uses explicit `withUnsafeBytes` copies to avoid an `NSSubrangeData` bug with `rangeOfData`
- **Mbox writes are byte-preserving**: CRLF→LF normalization and "From " escaping operate on `Data`, never through `String` (non-UTF-8 messages must not be transcoded)
- **Restore**: `appendMessage` sends `(\Seen)` as flag and the original INTERNALDATE; individual APPEND failures don't abort the run (5 consecutive failures do)
- **Import**: copies external `.mbox` files into the local backup folder (no IMAP connection)
- **Clean stop**: `requestStop()` sets a key in `stopRequested`, checked at every iteration of the download loop
- **Remote content blocked** in the HTML viewer (WKContentRuleList); user opts in per message
- **Passwords**: data-protection keychain (`kSecUseDataProtectionKeychain`) with automatic migration from the legacy file keychain and pre-1.5 UserDefaults

---

## Engineering Principles

### 1. Think Before Coding
Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First
Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.
- Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes
Touch only what you must. Clean up only your own mess.

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.
- Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution
Define success criteria. Loop until verified.

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]

Strong success criteria allow independent iteration. Weak criteria ("make it work") require constant clarification.
