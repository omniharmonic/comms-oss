import CommsClient
import CommsCore
import Foundation

/// Sprint Task 9 in the fixture: the server's rules for Mute / Archive / Status (with undo) and
/// owner folders, announced on the stream like the server does.
extension FixtureBackend {
    public var rowActions: RowActionSupport { state.withLock { $0.rowActions } }
    public func setRowActions(_ a: RowActionSupport) { state.withLock { $0.rowActions = a } }
    public var foldersSupported: Bool { state.withLock { $0.foldersSupported } }
    public func setFoldersSupported(_ on: Bool) { state.withLock { $0.foldersSupported = on } }
    /// Make the next row / folder calls fail (nil = succeed).
    public func setRowError(_ e: (any Error)?) { state.withLock { $0.rowError = e } }
    /// "mute:<id>:true", "archive:<id>:false", "status:<id>:urgent", "undo:<id>", "folder+:<name>",
    /// "add:<folder>:<ids>", … as made.
    public var rowCalls: [String] { state.withLock { $0.rowCalls } }
    public var currentFolders: [CommsChatFolder] { state.withLock { $0.folders } }

    /// Seed folders (and their members) directly.
    public func setFolders(_ folders: [(name: String, threadIDs: [String])]) {
        state.withLock { s in
            s.folders = []
            for (i, f) in folders.enumerated() {
                s.folderSeq += 1
                let id = "cf_fx\(s.folderSeq)"
                s.folders.append(CommsChatFolder(id: id, name: f.name, position: i, count: f.threadIDs.count))
                for t in f.threadIDs { Self.patch(&s, t) { $0.folderIds = (($0.folderIds ?? []) + [id]).sorted() } }
            }
        }
    }

    private static func patch(_ s: inout State, _ id: String, _ change: (inout CommsThread) -> Void) {
        guard let i = s.threads.firstIndex(where: { $0.id == id }) else { return }
        change(&s.threads[i])
        s.threadDetails[id]?.thread = s.threads[i]
    }

    private func rowCall(_ name: String) throws {
        try state.withLock { s in
            s.rowCalls.append(name)
            if let e = s.rowError { throw e }
        }
    }

    private func announce(_ threadID: String?, reason: String? = nil) {
        var payload: [String: JSONValue] = ["threadId": threadID.map { .string($0) } ?? .null]
        if let reason { payload["reason"] = .string(reason) }
        push(CommsEvent(id: "fx_row_\(UUID().uuidString)", kind: .threadUpdated, payload: .object(payload)))
    }

    private func thread(_ id: String, _ change: @Sendable (inout CommsThread) -> Void) throws -> CommsThread {
        try state.withLock { s in
            guard s.threads.contains(where: { $0.id == id }) else { throw CommsError.threadUnavailable }
            Self.patch(&s, id, change)
            return s.threads.first { $0.id == id }!
        }
    }

    public func setMuted(threadID: String, _ muted: Bool) async throws -> CommsThread {
        try rowCall("mute:\(threadID):\(muted)")
        let t = try thread(threadID) { $0.muted = muted }
        announce(threadID)
        return t
    }

    public func setArchived(threadID: String, _ archived: Bool) async throws -> CommsThread {
        try rowCall("archive:\(threadID):\(archived)")
        let t = try thread(threadID) { t in
            if archived { t.folder = .archived } else if t.folder == .archived { t.folder = .inbox }
        }
        announce(threadID)
        return t
    }

    public func setStatus(threadID: String, _ status: CommsThreadStatus) async throws -> CommsStatusChange {
        try rowCall("status:\(threadID):\(status.wire)")
        let before = state.withLock { s in s.threads.first { $0.id == threadID } }
        guard let before else { throw CommsError.threadUnavailable }
        // As the server: no vault note (iMessage / SMS without one) → no status.
        if before.noteId == nil, before.networks.contains(where: { $0 == .imessage || $0 == .sms }) { throw CommsError.noStatusNote }
        guard before.status != status else { return CommsStatusChange(thread: before, undo: nil) }
        let t = try thread(threadID) { $0.status = status }
        let undoID = "su_fx_\(UUID().uuidString.prefix(8))"
        state.withLock { $0.statusUndo[undoID] = (threadID, before.status, false) }
        announce(threadID)
        return CommsStatusChange(thread: t, undo: .init(id: undoID, status: before.status ?? .unclassified))
    }

    public func undoStatus(threadID: String, undoID: String) async throws -> CommsThread {
        try rowCall("undo:\(threadID)")
        let entry = state.withLock { s in s.statusUndo[undoID] }
        guard let entry, entry.threadID == threadID, !entry.used else { throw CommsError.undoUnavailable }
        state.withLock { $0.statusUndo[undoID]?.used = true }
        let t = try thread(threadID) { $0.status = entry.status }
        announce(threadID)
        return t
    }

    // MARK: Folders

    private func folderCount(_ s: State, _ id: String) -> Int { s.threads.filter { $0.folderIds?.contains(id) == true }.count }

    public func folders() async throws -> [CommsChatFolder] {
        try rowCall("folders")
        return state.withLock { s in s.folders.map { var f = $0; f.count = folderCount(s, f.id); return f } }
    }

    public func createFolder(name: String) async throws -> CommsChatFolder {
        try rowCall("folder+:\(name)")
        let f = try state.withLock { s -> CommsChatFolder in
            guard !s.folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw CommsError.folderExists }
            guard s.folders.count < 20 else { throw CommsError.folderLimit }
            s.folderSeq += 1
            let f = CommsChatFolder(id: "cf_fx\(s.folderSeq)", name: name, position: s.folders.count)
            s.folders.append(f)
            return f
        }
        announce(nil, reason: "folders")
        return f
    }

    public func renameFolder(id: String, name: String) async throws -> CommsChatFolder {
        try rowCall("folder~:\(id):\(name)")
        let f = try state.withLock { s -> CommsChatFolder in
            guard let i = s.folders.firstIndex(where: { $0.id == id }) else { throw CommsError.folderUnavailable }
            guard !s.folders.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw CommsError.folderExists }
            s.folders[i].name = name
            return s.folders[i]
        }
        announce(nil, reason: "folders")
        return f
    }

    public func deleteFolder(id: String) async throws {
        try rowCall("folder-:\(id)")
        try state.withLock { s in
            guard s.folders.contains(where: { $0.id == id }) else { throw CommsError.folderUnavailable }
            s.folders.removeAll { $0.id == id }
            for i in s.folders.indices { s.folders[i].position = i }
            for t in s.threads where t.folderIds?.contains(id) == true {
                Self.patch(&s, t.id) { t in
                    t.folderIds = t.folderIds?.filter { $0 != id }
                    if t.folderIds?.isEmpty == true { t.folderIds = nil }
                }
            }
        }
        announce(nil, reason: "folders")
    }

    public func reorderFolders(_ ids: [String]) async throws -> [CommsChatFolder] {
        try rowCall("order:" + ids.joined(separator: ","))
        let out = try state.withLock { s -> [CommsChatFolder] in
            guard Set(ids) == Set(s.folders.map(\.id)), ids.count == s.folders.count else { throw CommsError.foldersChanged }
            s.folders = ids.enumerated().compactMap { i, id in s.folders.first { $0.id == id }.map { var f = $0; f.position = i; return f } }
            return s.folders
        }
        announce(nil, reason: "folders")
        return out
    }

    public func addToFolder(id: String, threadIDs: [String]) async throws -> CommsChatFolder {
        try rowCall("add:\(id):" + threadIDs.joined(separator: ","))
        let f = try state.withLock { s -> CommsChatFolder in
            guard var f = s.folders.first(where: { $0.id == id }) else { throw CommsError.folderUnavailable }
            for t in threadIDs { guard s.threads.contains(where: { $0.id == t }) else { throw CommsError.threadUnavailable } }
            for t in threadIDs { Self.patch(&s, t) { $0.folderIds = Set(($0.folderIds ?? []) + [id]).sorted() } }
            f.count = folderCount(s, id)
            return f
        }
        for t in threadIDs { announce(t) }
        return f
    }

    public func removeFromFolder(id: String, threadIDs: [String]) async throws -> CommsChatFolder {
        try rowCall("remove:\(id):" + threadIDs.joined(separator: ","))
        let f = try state.withLock { s -> CommsChatFolder in
            guard var f = s.folders.first(where: { $0.id == id }) else { throw CommsError.folderUnavailable }
            for t in threadIDs {
                Self.patch(&s, t) { t in
                    t.folderIds = t.folderIds?.filter { $0 != id }
                    if t.folderIds?.isEmpty == true { t.folderIds = nil }
                }
            }
            f.count = folderCount(s, id)
            return f
        }
        for t in threadIDs { announce(t) }
        return f
    }
}
