import AppKit

@MainActor
func runWeChatLifecycleChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ClipHarbor-WeChatLifecycle-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("exports")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: source.appendingPathComponent("chat.dat"))
    let chat = "小王\n2026年10月31日 18:32\n[图片] chat.dat"
    let previous = try WeChatExport.export(text: chat, source: source, destination: destination)
    let existing = Set(try fm.contentsOfDirectory(atPath: destination.path))
    let partialReady = root.appendingPathComponent("partial-ready")
    let session = WeChatExportSession()
    session.start { progress in
        let workerFiles = FileManager.default
        return try WeChatExport.export(text: chat, source: source, destination: destination, progress: progress, isCancelled: {
            let newDirectories = Set((try? workerFiles.contentsOfDirectory(atPath: destination.path)) ?? []).subtracting(existing)
            let hasImage = newDirectories.contains { name in
                workerFiles.fileExists(atPath: destination.appendingPathComponent(name).appendingPathComponent("images/image-001.png").path)
            }
            if hasImage {
                try? Data().write(to: partialReady)
                let deadline = Date().addingTimeInterval(5)
                while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            }
            return Task.isCancelled
        })
    }
    let readyDeadline = Date().addingTimeInterval(5)
    while !fm.fileExists(atPath: partialReady.path) && Date() < readyDeadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let reachedPartialOutput = fm.fileExists(atPath: partialReady.path)
    assert(reachedPartialOutput && session.working, "test must reach an unfinished on-disk image")
    session.isTerminating = true
    let cleanupFailure = await session.cancelAndWait()
    assert(cleanupFailure == nil && !session.working && session.result == nil)
    let remaining = Set(try fm.contentsOfDirectory(atPath: destination.path))
    let oldImage = try Data(contentsOf: previous.directory.appendingPathComponent("images/image-001.png"))
    assert(remaining == existing && oldImage == png, "shutdown must remove its partial export and retain older results")
    session.start { _ in fatalError("new exports must be blocked while termination waits for history") }
    assert(!session.working)

    session.isTerminating = false
    let failureDestination = root.appendingPathComponent("failed-exports")
    try fm.createDirectory(at: failureDestination, withIntermediateDirectories: true)
    var lockedImages: [URL] = []
    defer {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failureDestination.path)
        for images in lockedImages { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: images.path) }
    }
    func waitUntilFinished() async throws {
        let deadline = Date().addingTimeInterval(5)
        while session.working && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        assert(!session.working, "export task timed out")
    }
    func failCleanup() async throws -> URL {
        let existing = Set(try fm.contentsOfDirectory(atPath: failureDestination.path))
        session.start { progress in
            let workerFiles = FileManager.default
            return try WeChatExport.export(text: chat, source: source, destination: failureDestination, progress: progress, isCancelled: {
                let outputs = Set((try? workerFiles.contentsOfDirectory(atPath: failureDestination.path)) ?? []).subtracting(existing)
                for name in outputs {
                    let images = failureDestination.appendingPathComponent(name).appendingPathComponent("images")
                    if workerFiles.fileExists(atPath: images.appendingPathComponent("image-001.png").path) {
                        try? workerFiles.setAttributes([.posixPermissions: 0o500], ofItemAtPath: images.path)
                        return true
                    }
                }
                return false
            })
        }
        try await waitUntilFinished()
        let outputs = Set(try fm.contentsOfDirectory(atPath: failureDestination.path)).subtracting(existing)
        assert(outputs.count == 1 && session.result == nil, "test must leave a real permission-blocked partial export")
        let failed = failureDestination.appendingPathComponent(outputs.first!)
        lockedImages.append(failed.appendingPathComponent("images"))
        let failure = await session.cancelAndWait()
        assert(failure?.contains(failed.path) == true && session.error?.contains(failed.path) == true)
        return failed
    }
    func removeFailedExport(_ directory: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent("images").path)
        try fm.removeItem(at: directory)
    }
    func exportSuccessfully() async throws {
        session.start { progress in
            try WeChatExport.export(text: "恢复后的导出", source: nil, destination: failureDestination, progress: progress)
        }
        try await waitUntilFinished()
        assert(session.result != nil && session.error == nil)
    }
    let firstFailure = try await failCleanup()
    let secondFailure = try await failCleanup()
    try removeFailedExport(firstFailure)
    try await exportSuccessfully()
    let unresolvedFailure = await session.cancelAndWait()
    assert(unresolvedFailure?.contains(firstFailure.path) == false, "a removed directory must stop warning")
    assert(unresolvedFailure?.contains(secondFailure.path) == true, "a successful export must not hide another unfinished directory")
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: failureDestination.path)
    let inaccessibleFailure = await session.cancelAndWait()
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failureDestination.path)
    assert(inaccessibleFailure?.contains(secondFailure.path) == true, "inaccessible must not be mistaken for removed")
    try removeFailedExport(secondFailure)
    try await exportSuccessfully()
    let resolvedFailure = await session.cancelAndWait()
    assert(resolvedFailure == nil, "removed partial exports must not cause a stale quit warning")
    print("WeChat lifecycle cancellation, shutdown guard, retained results and cleanup-error checks passed")
}
