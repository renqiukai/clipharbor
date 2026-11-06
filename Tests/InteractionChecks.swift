import AppKit

@MainActor
func runInteractionChecks() async {
    let html = "<head><style>body { background: url(https://invalid.example/image); }</style></head><p>A &amp; B&nbsp;&#x4E2D;&#25991;</p><p>第二<br>行</p><img src='https://invalid.example/image'><script>hidden()</script>"
    let text = plainTextFromHTML(html)
    assert(text.contains("A & B 中文") && text.contains("第二\n行"))
    assert(!text.contains("hidden") && !text.contains("https://") && !text.contains("background"))
    assert(plainTextFromHTML("<p title='a > b'>Visible &lt;tag&gt;</p>") == "Visible <tag>")
    let htmlRegressions: [(String, String)] = [
        ("<p>1 < 2 and 3 > 0</p>", "1 < 2 and 3 > 0"),
        ("<p>x<2 && y>3; &lt;keep&gt;</p>", "x<2 && y>3; <keep>"),
        ("<pre>if ready:\n    run()\n    done()</pre>", "if ready:\n    run()\n    done()"),
        ("<PRE title='a > b'><code>  if x &lt; 2:\n\twork()  </code></PRE>", "  if x < 2:\n\twork()  "),
        ("<p>before</p><pre>  code()\n    next()</pre><p>after</p>", "before\n  code()\n    next()\nafter"),
        ("<pre>  first</pre><pre>\tsecond</pre>", "  first\n\tsecond"),
        ("<p>before</p><pre>\n  code()\n</pre><p>after</p>", "before\n  code()\nafter"),
        ("<pre>  unfinished\n    code", "  unfinished\n    code"),
        ("<table><tr><th>商品</th><th>数量</th></tr><tr><td>A</td><td>12</td></tr></table>", "商品\t数量\nA\t12"),
        ("<!DOCTYPE html><html><body><p>Visible</p></body></html>", "Visible")
    ]
    for (source, expected) in htmlRegressions {
        assert(plainTextFromHTML(source) == expected, "HTML conversion changed visible content: \(source)")
        let clip = Clip.rich([[NSPasteboard.PasteboardType.html.rawValue: Data(source.utf8)]])
        assert(clip.plainText == expected)
    }
    let rich = Clip.rich([[NSPasteboard.PasteboardType.html.rawValue: Data(html.utf8)]])
    assert(rich.plainText == text && rich.previewLabel.contains("中文"))
    let utf16HTML = Clip.rich([[NSPasteboard.PasteboardType.html.rawValue: "<p>UTF16 中文</p>".data(using: .utf16)!]])
    assert(utf16HTML.plainText == "UTF16 中文")
    let mixedFiles = Clip.rich([[NSPasteboard.PasteboardType.fileURL.rawValue: Data("file:///tmp/a%20b.txt".utf8)], [NSPasteboard.PasteboardType.string.rawValue: Data("保留其他文字".utf8)], [NSPasteboard.PasteboardType.png.rawValue: Data([1])]])
    assert(mixedFiles.plainText == "/tmp/a b.txt\n保留其他文字" && mixedFiles.imageData.count == 1)
    assert(mixedFiles.previewLabel.contains("a b.txt"))
    let multipleImages = Clip.rich([[NSPasteboard.PasteboardType.png.rawValue: Data([1])], [NSPasteboard.PasteboardType.tiff.rawValue: Data([2])]])
    assert(multipleImages.plainText == nil && multipleImages.imageData.count == 2)
    assert(multipleImages.previewLabel == "2 张图片")
    assert(Clip.files(["file:///tmp/a%20b.txt"]).plainText == "/tmp/a b.txt")

    let editor = NSTextView(frame: .zero)
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
    editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    assert(editor.hasMarkedText())
    assert(historyNavigationKey(enter, editor: editor) == nil)
    assert(historyNavigationKey(down, editor: editor) == nil)
    editor.unmarkText()
    assert(historyNavigationKey(enter, editor: editor) == 36)
    assert(historyNavigationKey(down, editor: editor) == 125)

    let name = "ClipHarborInteractionTests-\(UUID().uuidString)"
    let board = NSPasteboard(name: NSPasteboard.Name(name))
    let defaults = UserDefaults(suiteName: name)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    defer {
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
    }
    let store = ClipboardStore(pasteboard: board, defaults: defaults, file: directory.appendingPathComponent("history.plist"), monitor: false)
    let controller = PasteController(trackApplications: false)
    let first = Clip.text("first")
    let second = Clip.text("second")
    for value in ["first", "second"] {
        board.clearContents()
        board.setString(value, forType: .string)
        store.poll()
    }
    var sent: [Clip] = []
    assert(store.copy(first))
    controller.queuePaste(first, store: store) { sent.append(first); return true }
    board.clearContents()
    board.setString("newer external content", forType: .string)
    try? await Task.sleep(nanoseconds: 450_000_000)
    assert(sent.isEmpty && store.history.count(for: first) == 0)
    assert(board.string(forType: .string) == "newer external content")
    assert(store.error?.contains("已取消") == true)

    assert(store.copy(first))
    controller.queuePaste(first, store: store) { sent.append(first); return true }
    assert(store.copy(second))
    controller.queuePaste(second, store: store) { sent.append(second); return true }
    try? await Task.sleep(nanoseconds: 450_000_000)
    assert(sent == [second])
    assert(store.history.count(for: first) == 0 && store.history.count(for: second) == 1)

    assert(store.copy(first))
    controller.queuePaste(first, store: store) { sent.append(first); return true }
    controller.cancelPendingPaste()
    try? await Task.sleep(nanoseconds: 450_000_000)
    assert(sent == [second] && store.history.count(for: first) == 0)

    board.clearContents()
    let item = NSPasteboardItem()
    item.setData(Data("<p>Plain paste</p>".utf8), forType: .html)
    board.writeObjects([item])
    store.poll()
    let original = store.history.items.first!
    assert(original.plainText == "Plain paste")
    assert(store.copy(.text(original.plainText!)))
    controller.queuePaste(original, store: store) { sent.append(original); return true }
    try? await Task.sleep(nanoseconds: 450_000_000)
    assert(store.history.count(for: original) == 1)
    assert(board.string(forType: .string) == "Plain paste" && board.data(forType: .html) == nil)

    var extractions = 0
    let cache = ClipTextCache(store: store) { item in
        extractions += 1
        return item.plainText
    }
    let firstPresentation = cache.presentation(for: original)
    assert(firstPresentation.plainText == "Plain paste" && firstPresentation.label == "Plain paste")
    assert(cache.presentation(for: original).label.localizedCaseInsensitiveContains("plain"))
    assert(cache.presentation(for: original).plainText == firstPresentation.plainText)
    assert(extractions == 1 && cache.cachedCount == 1, "Repeated row/search/preview access must reuse extracted text")
    _ = cache.presentation(for: first)
    _ = cache.presentation(for: second)
    assert(cache.cachedCount == 3 && extractions == 3)
    store.togglePin(original)
    assert(cache.presentation(for: original).label == "Plain paste" && extractions == 3)
    store.delete(first)
    assert(cache.cachedCount == 2, "Deletion must purge cached text without waiting for a view update")
    store.clear()
    assert(cache.cachedCount == 1, "Clear must retain only pinned text")
    store.delete(original)
    assert(cache.cachedCount == 0)
    _ = cache.presentation(for: original)
    assert(cache.cachedCount == 0, "A stale preview must not re-cache a deleted record")
    await requireSaved(store)
    print("Interaction checks passed: IME, HTML, image preview labels, paste races, original-item counts and text cache lifecycle")
}
