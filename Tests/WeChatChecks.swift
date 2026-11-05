import AppKit

func runWeChatChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ClipHarbor-WeChatChecks-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("exports")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
    bitmap.bitmapData![3] = 255
    func pixel(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Data {
        bitmap.bitmapData![0] = r
        bitmap.bitmapData![1] = g
        bitmap.bitmapData![2] = b
        return bitmap.representation(using: .png, properties: [:])!
    }
    let red = pixel(255, 0, 0)
    let green = pixel(0, 255, 0)
    let blue = pixel(0, 0, 255)
    let first = source.appendingPathComponent("real1.png")
    let second = source.appendingPathComponent("real2.png")
    try red.write(to: first)
    try green.write(to: second)
    try blue.write(to: source.appendingPathComponent("chat.dat"))
    let chat = "小王\n2026年10月31日 18:32\n[图片] chat.dat"
    let valid = try JSONSerialization.data(withJSONObject: [["text": chat, "file": first.path]])
    let conflict = try JSONSerialization.data(withJSONObject: [["text": chat, "file": first.path], ["text": chat, "file": second.path]])
    let duplicated = try JSONSerialization.data(withJSONObject: [["text": chat, "file": first.path], ["text": chat, "file": first.path]])
    for metadata in [conflict, duplicated] {
        let result = try WeChatExport.export(text: chat, source: source, destination: destination, clipboardMetadata: metadata)
        assert(result.matched == 0 && result.unmatched == 1, "conflicting metadata must not use the same-name decoy")
        let markdown = try String(contentsOf: result.directory.appendingPathComponent("conversation.md"), encoding: .utf8)
        assert(markdown.contains("关联冲突") && markdown.contains("[图片] chat.dat"))
    }
    let direct = try WeChatExport.export(text: chat, source: source, destination: destination, clipboardMetadata: valid)
    let actual = try Data(contentsOf: direct.directory.appendingPathComponent("images/image-001.png"))
    assert(actual == red && actual != blue && direct.matched == 1)
    let stale = try JSONSerialization.data(withJSONObject: [["text": chat.replacingOccurrences(of: "小王", with: "小李"), "file": first.path]])
    let staleResult = try WeChatExport.export(text: chat, source: source, destination: destination, clipboardMetadata: stale)
    assert(staleResult.matched == 0 && staleResult.unmatched == 1, "metadata must correspond to the current clipboard text")

    let bodyDate = "小王\n2026年10月31日 18:32\n请记录会议时间\n2026年11月5日 09:00\n请提前十分钟到"
    let ambiguous = WeChatExport.parse(bodyDate)
    assert(ambiguous.messages.isEmpty && ambiguous.preamble == bodyDate && ambiguous.warning != nil)
    let original = try WeChatExport.export(text: bodyDate, source: nil, destination: destination)
    let originalMarkdown = try String(contentsOf: original.directory.appendingPathComponent("conversation.md"), encoding: .utf8)
    assert(originalMarkdown.contains(bodyDate) && !originalMarkdown.contains("### 请记录会议时间"))
    let oneMessage = try JSONSerialization.data(withJSONObject: [["text": bodyDate]])
    let trusted = WeChatExport.parse(bodyDate, clipboardMetadata: oneMessage)
    assert(trusted.messages.count == 1 && trusted.messages[0].sender == "小王")
    assert(trusted.messages[0].content == "请记录会议时间\n2026年11月5日 09:00\n请提前十分钟到")
    assert(trusted.warning == nil)

    let next = "小李\n2026年10月31日 18:33\n收到"
    let ordinary = "小王\n2026年10月31日 18:32\n第一行\n第二行"
    let twoMessages = ordinary + "\n\n" + next
    assert(WeChatExport.parse(twoMessages).messages.count == 2, "normal two-message text should remain recognizable")
    let twoMetadata = try JSONSerialization.data(withJSONObject: [["text": ordinary], ["text": next]])
    let parsedTwo = WeChatExport.parse(twoMessages, clipboardMetadata: twoMetadata)
    assert(parsedTwo.messages.count == 2 && parsedTwo.messages[1].sender == "小李" && parsedTwo.warning == nil)
    let bodyWithBlank = bodyDate.replacingOccurrences(of: "请记录会议时间", with: "\n请记录会议时间")
    let blankResult = try WeChatExport.export(text: bodyWithBlank, source: nil, destination: destination)
    let blankMarkdown = try String(contentsOf: blankResult.directory.appendingPathComponent("conversation.md"), encoding: .utf8)
    assert(blankMarkdown.contains(bodyWithBlank) && !blankMarkdown.contains("### 请记录会议时间"))
    assert(!blankResult.warnings.isEmpty)

    let existing = Set(try fm.contentsOfDirectory(atPath: destination.path))
    var cancelled = false
    var scanned = 0
    do {
        _ = try WeChatExport.export(text: "[图片] missing.dat", source: source, destination: destination,
                                    progress: { count in scanned = count; if count > 0 { cancelled = true } },
                                    isCancelled: { cancelled })
        assertionFailure("cancelled search must throw")
    } catch is CancellationError { }
    assert(scanned == 1)
    let afterSearch = Set(try fm.contentsOfDirectory(atPath: destination.path))
    assert(afterSearch == existing)

    var sawPartialImage = false
    do {
        _ = try WeChatExport.export(text: chat, source: source, destination: destination, clipboardMetadata: valid,
                                    isCancelled: {
            let newDirectories = Set((try? fm.contentsOfDirectory(atPath: destination.path)) ?? []).subtracting(existing)
            sawPartialImage = newDirectories.contains { name in
                fm.fileExists(atPath: destination.appendingPathComponent(name).appendingPathComponent("images/image-001.png").path)
            }
            return sawPartialImage
        })
        assertionFailure("cancellation after image copy must throw")
    } catch is CancellationError { }
    assert(sawPartialImage, "test must cancel after an output image has been created")
    let afterPartial = Set(try fm.contentsOfDirectory(atPath: destination.path))
    let previousImage = try Data(contentsOf: direct.directory.appendingPathComponent("images/image-001.png"))
    assert(afterPartial == existing, "cancel must remove only its incomplete result")
    assert(previousImage == red)
    print("WeChat conflict, metadata, message boundaries, scan cancellation and partial-output cleanup checks passed")
}
