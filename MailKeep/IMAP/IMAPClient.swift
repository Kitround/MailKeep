import Foundation
import Network

actor IMAPClient {
    private var connection: NWConnection?
    private var receiveBuffer: Data = Data()
    private var tagCounter: Int = 1
    private let timeoutSeconds: TimeInterval = 30
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Connect (IMAPS — TLS direct sur port 993)

    func connect(host: String, port: Int = 993) async throws {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: NWParameters.tls
        )
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectContinuation = cont
            conn.stateUpdateHandler = { [weak self] state in
                // Dispatch onto the actor to avoid captured mutable state
                Task { await self?.handleConnectState(state) }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        // Discard server greeting
        _ = try await receiveLine()
    }

    private func handleConnectState(_ state: NWConnection.State) {
        guard let cont = connectContinuation else { return }
        switch state {
        case .ready:
            connectContinuation = nil
            cont.resume()
        case .failed(let error):
            connectContinuation = nil
            cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
        case .cancelled:
            connectContinuation = nil
            cont.resume(throwing: IMAPError.serverDisconnected)
        default:
            break
        }
    }

    // MARK: - Login / Logout

    func login(username: String, password: String) async throws {
        let tag = nextTag()
        let cmd = "\(tag) LOGIN \(IMAPParser.quote(username)) \(IMAPParser.quote(password))\r\n"
        try await sendRaw(cmd)
        let resp = try await awaitTagged(tag: tag)
        guard case .tagged(_, let status, let text) = resp.tagged, status == .ok else {
            throw IMAPError.authenticationFailed(responseText(resp.tagged))
        }
        _ = text
    }

    func logout() async throws {
        let tag = nextTag()
        try await sendRaw("\(tag) LOGOUT\r\n")
        _ = try? await awaitTagged(tag: tag)
        connection?.cancel()
        connection = nil
    }

    // MARK: - List Folders

    func listFolders() async throws -> [String] {
        let tag = nextTag()
        try await sendRaw("\(tag) LIST \"\" \"*\"\r\n")
        let resp = try await awaitTagged(tag: tag)
        var folders: [String] = []
        for line in resp.untagged {
            guard case .untagged(let kw, let rest) = line, kw.uppercased() == "LIST" else { continue }
            if let name = IMAPParser.parseFolderName(from: rest) {
                folders.append(name)
            }
        }
        return folders
    }

    // MARK: - Select Folder

    func selectFolder(_ name: String) async throws -> FolderStatus {
        let tag = nextTag()
        try await sendRaw("\(tag) SELECT \(IMAPParser.quote(name))\r\n")
        let resp = try await awaitTagged(tag: tag)

        guard case .tagged(_, let status, _) = resp.tagged, status == .ok else {
            throw IMAPError.folderNotFound(name)
        }

        var fs = FolderStatus(name: name)
        for line in resp.untagged {
            switch line {
            case .untagged(let kw, let rest):
                if let exists = IMAPParser.parseExists(keyword: kw, rest: rest) {
                    fs.exists = exists
                }
                if let uv = IMAPParser.parseUIDValidity(from: "* \(kw) \(rest)") {
                    fs.uidValidity = uv
                }
                if let un = IMAPParser.parseUIDNext(from: "* \(kw) \(rest)") {
                    fs.uidNext = un
                }
            default: break
            }
        }
        return fs
    }

    // MARK: - Fetch UIDs

    /// Fetches every UID matching the given filter (ALL, SEEN, UNSEEN, FLAGGED).
    func fetchAllUIDs(filter: MessageFilter) async throws -> [UInt32] {
        try await searchUIDs(command: "UID SEARCH \(filter.imapCriterion)")
    }

    private func searchUIDs(command: String) async throws -> [UInt32] {
        let tag = nextTag()
        try await sendRaw("\(tag) \(command)\r\n")
        let resp = try await awaitTagged(tag: tag)
        // RFC 3501 §7.4.2 allows the server to spread results across multiple SEARCH lines.
        var uids: [UInt32] = []
        for line in resp.untagged {
            if case .untagged(let kw, let rest) = line, kw.uppercased() == "SEARCH" {
                uids.append(contentsOf: IMAPParser.parseSearchUIDs(from: rest))
            }
        }
        return Array(Set(uids)).sorted()
    }

    // MARK: - Fetch Message

    func fetchMessage(uid: UInt32) async throws -> FetchedMessage {
        let tag = nextTag()
        // BODY.PEEK[] lit le contenu sans modifier le flag \Seen
        try await sendRaw("\(tag) UID FETCH \(uid) (FLAGS INTERNALDATE BODY.PEEK[])\r\n")
        let resp = try await awaitTagged(tag: tag)

        // Find the untagged FETCH response with literal body
        for line in resp.untagged {
            if case .untaggedWithLiteral(_, let header, let body) = line {
                let internalDate = IMAPParser.parseInternalDate(from: header)
                let parsedUID = IMAPParser.parseUID(from: header) ?? uid
                return FetchedMessage(uid: parsedUID, rfc822: body, internalDate: internalDate)
            }
        }
        throw IMAPError.unexpectedResponse("No FETCH literal for UID \(uid)")
    }

    // MARK: - Append (restore)

    func appendMessage(to folder: String, data: Data, internalDate: String?) async throws {
        let tag = nextTag()
        let size = data.count
        var cmd = "\(tag) APPEND \(IMAPParser.quote(folder)) (\\Seen)"
        if let date = internalDate, !date.isEmpty {
            cmd += " \"\(date)\""
        }
        cmd += " {\(size)}\r\n"
        try await sendRaw(cmd)

        // Wait for continuation "+"
        let contLine = try await receiveLine()
        guard contLine.hasPrefix("+") else {
            throw IMAPError.appendFailed("Expected continuation, got: \(contLine)")
        }

        try await sendData(data)
        try await sendRaw("\r\n")

        let resp = try await awaitTagged(tag: tag)
        guard case .tagged(_, let status, let text) = resp.tagged, status == .ok else {
            throw IMAPError.appendFailed(responseText(resp.tagged))
        }
        _ = text
    }

    // MARK: - Low-level I/O

    private func sendRaw(_ string: String) async throws {
        guard let conn = connection else { throw IMAPError.serverDisconnected }
        let data = string.data(using: .utf8)!
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let e = error { cont.resume(throwing: e) }
                else { cont.resume() }
            })
        }
    }

    private func sendData(_ data: Data) async throws {
        guard let conn = connection else { throw IMAPError.serverDisconnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let e = error { cont.resume(throwing: e) }
                else { cont.resume() }
            })
        }
    }

    private func rawReceive() async throws -> Data {
        guard let conn = connection else { throw IMAPError.serverDisconnected }
        return try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let e = error { cont.resume(throwing: e); return }
                if isComplete && (data == nil || data!.isEmpty) {
                    cont.resume(throwing: IMAPError.serverDisconnected); return
                }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    func receiveLine() async throws -> String {
        let crlf = Data([0x0D, 0x0A])
        while true {
            if let range = receiveBuffer.range(of: crlf) {
                // Force genuine heap copies — removeSubrange/slice on NSData-backed Data creates
                // NSSubrangeData with an accumulating internal offset that overflows rangeOfData.
                let lineData = receiveBuffer.withUnsafeBytes { src in
                    Data(bytes: src.baseAddress!, count: range.lowerBound)
                }
                let upperBound = range.upperBound
                let remaining = receiveBuffer.count - upperBound
                receiveBuffer = remaining > 0
                    ? receiveBuffer.withUnsafeBytes { src in
                        Data(bytes: src.baseAddress!.advanced(by: upperBound), count: remaining)
                      }
                    : Data()
                return String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .isoLatin1) ?? ""
            }
            let chunk = try await rawReceive()
            receiveBuffer.append(chunk)
        }
    }

    private func receiveBytes(_ count: Int) async throws -> Data {
        guard count < 500_000_000 else { throw IMAPError.literalTooLarge(count) }
        while receiveBuffer.count < count {
            let chunk = try await rawReceive()
            receiveBuffer.append(chunk)
        }
        // Force genuine heap copies — removeFirst on NSData-backed Data creates NSSubrangeData
        // with an accumulating internal offset that overflows rangeOfData:options:range:.
        let result = receiveBuffer.withUnsafeBytes { src in
            Data(bytes: src.baseAddress!, count: count)
        }
        let remaining = receiveBuffer.count - count
        receiveBuffer = remaining > 0
            ? receiveBuffer.withUnsafeBytes { src in
                Data(bytes: src.baseAddress!.advanced(by: count), count: remaining)
              }
            : Data()
        return result
    }

    // MARK: - Command helpers

    func awaitTagged(tag: String) async throws -> CollectedResponse {
        var untagged: [IMAPResponseLine] = []
        var lastLiteral: Data? = nil

        while true {
            let line = try await receiveLine()
            guard !line.isEmpty else { continue }

            if let literalSize = IMAPParser.extractLiteralSize(from: line) {
                let bodyData = try await receiveBytes(literalSize)
                // consume trailing CRLF or ")" line after literal
                let closingLine = try await receiveLine()
                _ = closingLine
                lastLiteral = bodyData
                let parsed = IMAPParser.parseLine(line)
                if case .untagged(let kw, let rest) = parsed {
                    untagged.append(.untaggedWithLiteral(keyword: kw, header: "* \(kw) \(rest)", body: bodyData))
                }
                continue
            }

            let parsed = IMAPParser.parseLine(line)
            switch parsed {
            case .tagged(let t, _, _) where t == tag:
                return CollectedResponse(tagged: parsed, untagged: untagged, literalBody: lastLiteral)
            case .tagged(let t, _, _):
                // unexpected tag — treat as untagged
                untagged.append(.untagged(keyword: t, rest: line))
            case .untagged, .continuation:
                untagged.append(parsed)
            case .untaggedWithLiteral:
                untagged.append(parsed)
            }
        }
    }

    private func nextTag() -> String {
        let tag = String(format: "A%04d", tagCounter)
        tagCounter += 1
        return tag
    }

    private func responseText(_ line: IMAPResponseLine) -> String {
        switch line {
        case .tagged(_, _, let text): return text
        case .untagged(let kw, let rest): return "\(kw) \(rest)"
        default: return ""
        }
    }
}
