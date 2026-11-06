import Foundation

actor HistoryFile {
    let file: URL
    private var savedRevision = -1

    init(file: URL) { self.file = file }

    nonisolated static func protect(_ file: URL) throws {
        let fm = FileManager.default
        let directory = file.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fm.fileExists(atPath: file.path) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    func save(_ archive: Archive, revision: Int) throws {
        // Older queued snapshots must never overwrite a newer completed save.
        guard revision > savedRevision else { return }
        try Task.checkCancellation()
        try Self.protect(file)
        let data = try PropertyListEncoder().encode(archive)
        try Task.checkCancellation()
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        savedRevision = revision
    }

    func recover(_ archive: Archive, revision: Int) throws -> URL? {
        try Self.protect(file)
        var backup: URL?
        if FileManager.default.fileExists(atPath: file.path) {
            let url = file.deletingLastPathComponent().appendingPathComponent("history-damaged-\(UUID().uuidString).plist")
            try FileManager.default.copyItem(at: file, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            backup = url
        }
        try save(archive, revision: revision)
        return backup
    }
}
