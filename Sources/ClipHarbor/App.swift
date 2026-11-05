import AppKit
import SwiftUI
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private let pasteController = PasteController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var conversionWindow: NSWindow?
    private var lastShortcut = ""
    private var defaultsObserver: NSObjectProtocol?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipHarbor")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 440, height: 520)
        popover.contentViewController = NSHostingController(rootView: HistoryView(store: store, convert: { [weak self] in self?.showWeChatExport() }) { [weak self] item, plainText in
            guard let self else { return }
            self.popover.performClose(nil)
            self.pasteController.paste(item, store: self.store, plainText: plainText)
        })
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.toggle() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.registerShortcut() }
        }
        registerShortcut()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        pasteController.cancelPendingPaste()
        popover.performClose(nil)
        store.prepareToTerminate()
        Task { @MainActor in
            var shouldQuit = await store.flush()
            if !shouldQuit {
                let alert = NSAlert()
                alert.messageText = "历史记录尚未保存"
                alert.informativeText = "\(store.storageStatus ?? "无法保存最后的修改。")\n留在应用中可重试保存；仍然退出会丢失尚未保存的修改。"
                alert.addButton(withTitle: "留在应用")
                alert.addButton(withTitle: "仍然退出")
                NSApp.activate(ignoringOtherApps: true)
                shouldQuit = alert.runModal() == .alertSecondButtonReturn
            }
            if !shouldQuit { store.cancelTermination() }
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    private func showWeChatExport() {
        popover.performClose(nil)
        if conversionWindow?.isVisible != true {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "微信聊天转上下文"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: WeChatView())
            window.center()
            conversionWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        conversionWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            pasteController.rememberFrontmost()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func registerShortcut() {
        let value = UserDefaults.standard.string(forKey: "shortcut") ?? "optionShiftV"
        guard value != lastShortcut else { return }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        lastShortcut = value
        guard value != "disabled" else { return }
        let modifiers = value == "controlOptionV" ? controlKey | optionKey : optionKey | shiftKey
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(modifiers), EventHotKeyID(signature: 0x434C4950, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { store.error = "快捷键注册失败，可能已被其他应用占用。请换一个快捷键。" }
    }
}

@main
struct ClipHarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}
