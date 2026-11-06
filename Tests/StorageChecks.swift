import AppKit
import Combine

@MainActor func runStorageChecks() async {
    let suite = "ClipHarborStorage-\(UUID().uuidString)"
    let board = NSPasteboard(name: NSPasteboard.Name(suite))
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let file = directory.appendingPathComponent("history.plist")
    let fm = FileManager.default
    defer {
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? fm.removeItem(at: directory)
    }
    func copyText(_ text: String, to store: ClipboardStore) {
        board.clearContents()
        board.setString(text, forType: .string)
        store.poll()
    }
    func permissions(_ url: URL) -> Int {
        (try! fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }
    func read(_ url: URL) -> Archive {
        try! PropertyListDecoder().decode(Archive.self, from: Data(contentsOf: url))
    }
    let store = ClipboardStore(pasteboard: board, defaults: defaults, file: file, monitor: false)
    copyText("keep", to: store)
    store.togglePin(.text("keep"))
    store.recordUse(.text("keep"))
    copyText("delete", to: store)
    store.recordUse(.text("delete"))
    store.delete(.text("delete"))
    await requireSaved(store)
    assert(read(file).items == [.text("keep")])
    assert(read(file).usage?.count == 1)
    assert(permissions(directory) == 0o700 && permissions(file) == 0o600)

    copyText("ordinary", to: store)
    await requireSaved(store)
    let originalFile = try! fm.attributesOfItem(atPath: file.path)
    var historyUpdates = 0
    let observation = store.$history.dropFirst().sink { _ in historyUpdates += 1 }
    for value in [" \n\t", "keep", "ordinary"] { copyText(value, to: store) }
    await requireSaved(store)
    let unchangedFile = try! fm.attributesOfItem(atPath: file.path)
    assert(historyUpdates == 0, "unchanged clipboard content must not redraw the history")
    assert(originalFile[.systemFileNumber] as? NSNumber == unchangedFile[.systemFileNumber] as? NSNumber)
    assert(originalFile[.modificationDate] as? Date == unchangedFile[.modificationDate] as? Date)
    observation.cancel()
    copyText("new ordinary", to: store)
    copyText("ordinary", to: store)
    await requireSaved(store)
    assert(read(file).items.prefix(3) == [.text("keep"), .text("ordinary"), .text("new ordinary")])

    store.setPaused(true)
    copyText("private", to: store)
    assert(!store.history.items.contains(.text("private")))
    let paused = ClipboardStore(pasteboard: board, defaults: defaults, file: file, monitor: false)
    assert(paused.isPaused)
    board.clearContents()
    board.setString("still private", forType: .string)
    store.setPaused(false)
    store.poll()
    assert(!store.history.items.contains(.text("still private")))
    copyText("after pause", to: store)
    assert(store.history.items.contains(.text("after pause")))

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let tiff = bitmap.representation(using: .tiff, properties: [:])!
    let first = NSPasteboardItem(), second = NSPasteboardItem()
    first.setData(png, forType: .png)
    second.setData(tiff, forType: .tiff)
    board.clearContents()
    board.writeObjects([first, second])
    store.poll()
    guard case .rich(let parts) = store.history.items[store.history.pinned.count] else {
        fatalError("multiple images not preserved")
    }
    assert(parts.count == 2)
    assert(store.copy(.rich(parts)))
    assert(board.pasteboardItems?.count == 2)
    assert(board.pasteboardItems?[0].data(forType: .png) == png)
    assert(board.pasteboardItems?[1].data(forType: .tiff) == tiff)
    let version = store.clipboardVersion
    assert(store.isCurrentClipboard(version))
    board.clearContents()
    assert(!store.isCurrentClipboard(version))

    let mixedFile = NSPasteboardItem(), mixedImage = NSPasteboardItem()
    mixedFile.setString("file:///tmp/example.txt", forType: .fileURL)
    mixedImage.setData(png, forType: .png)
    board.writeObjects([mixedFile, mixedImage])
    store.poll()
    let mixed = store.history.items[store.history.pinned.count]
    assert(store.copy(mixed))
    assert(board.pasteboardItems?.count == 2)
    assert(board.pasteboardItems?[0].string(forType: .fileURL) == "file:///tmp/example.txt")
    assert(board.pasteboardItems?[1].data(forType: .png) == png)

    store.delete(.text("keep"))
    assert(store.history.pinned.isEmpty && store.history.count(for: .text("keep")) == 0)
    store.prepareToTerminate()
    copyText("during termination", to: store)
    assert(!store.history.items.contains(.text("during termination")))
    await requireSaved(store)
    store.cancelTermination()
    store.poll()
    assert(store.history.items.contains(.text("during termination")))
    await requireSaved(store)

    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try! fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    _ = ClipboardStore(pasteboard: board, defaults: defaults, file: file, monitor: false)
    assert(permissions(directory) == 0o700 && permissions(file) == 0o600)

    let corruptFile = directory.appendingPathComponent("corrupt.plist")
    let damaged = Data("not a property list".utf8)
    try! damaged.write(to: corruptFile)
    let recovery = ClipboardStore(pasteboard: board, defaults: defaults, file: corruptFile, monitor: false)
    recovery.error = nil
    copyText("before recovery", to: recovery)
    assert(recovery.needsRecovery && recovery.storageStatus != nil)
    assert(try! Data(contentsOf: corruptFile) == damaged)
    recovery.recoverHistory()
    copyText("during recovery", to: recovery)
    for _ in 0..<500 where recovery.needsRecovery {
        try! await Task.sleep(nanoseconds: 10_000_000)
    }
    assert(!recovery.needsRecovery, recovery.storageStatus ?? "recovery timed out")
    await requireSaved(recovery)
    assert(read(corruptFile).items.contains(.text("before recovery")))
    assert(read(corruptFile).items.contains(.text("during recovery")))
    let backups = try! fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("history-damaged-") }
    assert(backups.count == 1 && (try! Data(contentsOf: backups[0])) == damaged)
    assert(permissions(backups[0]) == 0o600)

    let versionedFile = directory.appendingPathComponent("versioned.plist")
    let writer = HistoryFile(file: versionedFile)
    try! await writer.save(Archive(items: [.text("new")], pinned: []), revision: 3)
    try! await writer.save(Archive(items: [.text("old")], pinned: []), revision: 2)
    assert(read(versionedFile).items == [.text("new")])

    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await writer.save(Archive(items: [.text("cancelled")], pinned: []), revision: 4)
    }
    do {
        try await cancelled.value
        fatalError("cancelled queued snapshots must not write")
    } catch is CancellationError {} catch { fatalError("unexpected cancellation error: \(error)") }
    assert(read(versionedFile).items == [.text("new")])
    try! await writer.save(Archive(items: [.text("latest")], pinned: []), revision: 5)
    assert(read(versionedFile).items == [.text("latest")])

    let blockedFile = directory.appendingPathComponent("blocked.plist")
    try! fm.createDirectory(at: blockedFile, withIntermediateDirectories: false)
    let retryWriter = HistoryFile(file: blockedFile)
    let snapshot = Archive(items: [.text("retry")], pinned: [])
    do {
        try await retryWriter.save(snapshot, revision: 1)
        fatalError("write over a directory must fail")
    } catch {}
    try! fm.removeItem(at: blockedFile)
    try! await retryWriter.save(snapshot, revision: 1)
    assert(read(blockedFile).items == snapshot.items)
    print("Recovery, permissions, multi-image, pause, deletion and ordered background saves passed")
}
