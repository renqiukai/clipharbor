import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ChatMessage {
    let sender: String
    let time: String
    let content: String
}

struct ChatParse {
    let messages: [ChatMessage]
    let preamble: String
    var warning: String? = nil
}

enum WeChatExport {
    private struct CopiedMessage: Decodable {
        let text: String?
        let file: String?
    }

    static let timePattern = try! NSRegularExpression(pattern: #"^\d{4}年\d{1,2}月\d{1,2}日\s+\d{1,2}:\d{2}(?::\d{2})?$"#)
    static let imagePattern = try! NSRegularExpression(pattern: #"\[图片\][ \t]+([^\r\n]+?\.dat)(?=\s|$)"#, options: [.caseInsensitive])

    private static func copiedMessages(_ data: Data?) -> [CopiedMessage]? {
        guard let data, data.count <= 10_000_000 else { return nil }
        return try? JSONDecoder().decode([CopiedMessage].self, from: data)
    }

    private static func messageTexts(_ messages: [CopiedMessage], matching text: String) -> [String]? {
        guard !messages.isEmpty else { return nil }
        var remaining = text.replacingOccurrences(of: "\r\n", with: "\n")[...]
        var parts: [String] = []
        for message in messages {
            guard let text = message.text else { return nil }
            let part = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = remaining.drop(while: { $0.isWhitespace })
            guard !part.isEmpty, remaining.hasPrefix(part) else { return nil }
            remaining = remaining.dropFirst(part.count)
            parts.append(part)
        }
        return remaining.allSatisfy(\.isWhitespace) ? parts : nil
    }

    static func parse(_ text: String, clipboardMetadata: Data? = nil) -> ChatParse {
        parse(text, copiedMessages: copiedMessages(clipboardMetadata))
    }

    private static func parse(_ text: String, copiedMessages: [CopiedMessage]?) -> ChatParse {
        if let copiedMessages, let parts = messageTexts(copiedMessages, matching: text) {
            let messages = parts.compactMap { part -> ChatMessage? in
                let lines = part.components(separatedBy: "\n")
                guard lines.count >= 2, !lines[0].trimmingCharacters(in: .whitespaces).isEmpty,
                      timePattern.firstMatch(in: lines[1], range: NSRange(lines[1].startIndex..., in: lines[1])) != nil else { return nil }
                return ChatMessage(sender: lines[0], time: lines[1], content: lines.dropFirst(2).joined(separator: "\n"))
            }
            if messages.count == parts.count { return ChatParse(messages: messages, preamble: "") }
            return ChatParse(messages: [], preamble: text, warning: "微信复制数据中的消息头不完整，已保留原始文本。")
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var headers: [(Int, String, String)] = []
        for i in lines.indices where i > 0 {
            let time = lines[i].trimmingCharacters(in: .whitespaces)
            let range = NSRange(time.startIndex..., in: time)
            let sender = lines[i - 1].trimmingCharacters(in: .whitespaces)
            let senderRange = NSRange(sender.startIndex..., in: sender)
            if !sender.isEmpty, timePattern.firstMatch(in: sender, range: senderRange) == nil,
               (headers.last.map { i - 1 >= $0.0 + 2 } ?? true),
               timePattern.firstMatch(in: time, range: range) != nil {
                headers.append((i - 1, sender, time))
            }
        }
        guard !headers.isEmpty else { return ChatParse(messages: [], preamble: text) }
        if headers.dropFirst().contains(where: { $0.0 == 0 || !lines[$0.0 - 1].trimmingCharacters(in: .whitespaces).isEmpty }) {
            return ChatParse(messages: [], preamble: text, warning: "正文中的日期与消息头无法区分，已保留原始文本。")
        }
        let preamble = lines[..<headers[0].0].joined(separator: "\n")
        let messages = headers.indices.map { index in
            let header = headers[index]
            let end = index + 1 < headers.count ? headers[index + 1].0 : lines.count
            return ChatMessage(sender: header.1, time: header.2,
                               content: lines[(header.0 + 2)..<end].joined(separator: "\n"))
        }
        return ChatParse(messages: messages, preamble: preamble,
                         warning: headers.count > 1 ? "纯文本消息边界未经微信复制数据确认，识别条数仅供参考；已保留原始文本。" : nil)
    }

    static func references(in text: String) -> [String] {
        imagePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    struct Result {
        let directory: URL
        let messages: Int
        let matched: Int
        let unmatched: Int
        let warnings: [String]
    }

    static func export(text: String, source: URL?, destination: URL, clipboardMetadata: Data? = nil,
                       progress: (Int) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { Task.isCancelled }) throws -> Result {
        func checkCancellation() throws {
            if isCancelled() { throw CancellationError() }
        }
        try checkCancellation()
        let fm = FileManager.default
        let messages = copiedMessages(clipboardMetadata)
        let parsed = parse(text, copiedMessages: messages)
        let refs = references(in: text)
        let names = Set(refs.filter { $0 == URL(fileURLWithPath: $0).lastPathComponent && $0 != "." && $0 != ".." })
        var candidates: [String: [URL]] = [:]
        var warnings = parsed.warning.map { [$0] } ?? []
        var searchIncomplete = false
        var direct: [String: URL] = [:]
        var blocked: Set<String> = []
        if let source, let messages {
            let root = source.standardizedFileURL.resolvingSymlinksInPath()
            var associations: [String: [URL]] = [:]
            let metadataMatches = messageTexts(messages, matching: text) != nil
            for message in messages {
                try checkCancellation()
                let messageRefs = references(in: message.text ?? "")
                if !metadataMatches || messageRefs.count > 1 {
                    blocked.formUnion(messageRefs.filter { names.contains($0) })
                    continue
                }
                guard messageRefs.count == 1, let name = messageRefs.first,
                      names.contains(name),
                      let path = message.file, path.hasPrefix("/") else { continue }
                guard refs.filter({ $0 == name }).count == 1 else { blocked.insert(name); continue }
                let file = URL(fileURLWithPath: path).standardizedFileURL
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
                associations[name, default: []].append(file)
            }
            let repeatedPaths = Dictionary(grouping: associations.values.flatMap { $0 }, by: { $0.resolvingSymlinksInPath() })
            for (name, urls) in associations {
                if urls.count == 1 && repeatedPaths[urls[0].resolvingSymlinksInPath()]?.count == 1 && !blocked.contains(name) {
                    direct[name] = urls[0]
                } else { blocked.insert(name) }
            }
        }
        let namesToSearch = names.subtracting(direct.keys).subtracting(blocked)
        var scanned = 0
        progress(scanned)
        if let source, !namesToSearch.isEmpty {
            let root = source.standardizedFileURL.resolvingSymlinksInPath()
            let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in
                searchIncomplete = true
                warnings.append("有目录无法读取，搜索结果可能不完整；未自动匹配图片。")
                return !isCancelled()
            })
            guard let enumerator else { throw CocoaError(.fileReadNoPermission) }
            for case let url as URL in enumerator {
                try checkCancellation()
                scanned += 1
                if scanned == 1 || scanned % 100 == 0 { progress(scanned) }
                guard namesToSearch.contains(url.lastPathComponent) else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                    searchIncomplete = true
                    warnings.append("有文件无法检查，搜索结果可能不完整；未自动匹配图片。")
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
                candidates[url.lastPathComponent, default: []].append(url)
            }
        }
        progress(scanned)
        try checkCancellation()
        let output = destination.appendingPathComponent("微信聊天-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
        try checkCancellation()
        let images = output.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var replacements: [String: String] = [:]
        var missing: [String: String] = [:]
        for name in Set(refs).sorted() {
            try checkCancellation()
            guard names.contains(name) else { missing[name] = "文件名包含路径，未自动匹配"; continue }
            guard source != nil else { missing[name] = "未选择图片搜索目录"; continue }
            guard !blocked.contains(name) else { missing[name] = "微信复制数据与当前文字不一致或关联冲突，未自动匹配"; continue }
            guard direct[name] != nil || !searchIncomplete else { missing[name] = "搜索不完整，无法确认唯一性"; continue }
            let matches = direct[name].map { [$0] } ?? candidates[name] ?? []
            guard matches.count == 1 else {
                missing[name] = matches.isEmpty ? "未找到同名文件" : "找到多个同名文件，无法确认对应关系"
                continue
            }
            guard let image = CGImageSourceCreateWithURL(matches[0] as CFURL, nil),
                  CGImageSourceGetCount(image) > 0,
                  CGImageSourceCreateImageAtIndex(image, 0, nil) != nil,
                  let typeID = CGImageSourceGetType(image) as String?,
                  let type = UTType(typeID), type.conforms(to: .image),
                  let ext = type.preferredFilenameExtension else {
                missing[name] = "文件不是可识别的图片，可能是加密的微信文件"
                continue
            }
            let filename = String(format: "image-%03d.%@", replacements.count + 1, ext)
            try fm.copyItem(at: matches[0], to: images.appendingPathComponent(filename))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: images.appendingPathComponent(filename).path)
            try checkCancellation()
            replacements[name] = filename
        }
        func render(_ content: String) -> String {
            var result = content
            let matches = imagePattern.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches.reversed() {
                guard let nameRange = Range(match.range(at: 1), in: content),
                      let matchRange = Range(match.range, in: result) else { continue }
                let name = String(content[nameRange])
                if let file = replacements[name] { result.replaceSubrange(matchRange, with: "![图片](images/\(file))") }
            }
            return result
        }
        var markdown = "# 微信聊天记录\n\n"
        if parsed.messages.isEmpty || parsed.warning != nil {
            markdown += (parsed.warning ?? "无法识别消息头，以下保留原始文本。") + "\n\n" + render(text) + "\n"
        } else {
            if !parsed.preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markdown += "## 未解析的开头\n\n" + render(parsed.preamble) + "\n\n"
            }
            for message in parsed.messages {
                let sender = message.sender.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "#", with: "\\#")
                markdown += "### \(sender) · \(message.time)\n\n\(render(message.content))\n\n"
            }
        }
        markdown += "\n## 图片关联报告\n\n"
        if refs.isEmpty { markdown += "未发现 [图片] 文件引用。\n" }
        for name in Set(refs).sorted() {
            if let file = replacements[name] { markdown += "- \(name)：\(direct[name] == nil ? "按唯一同名文件匹配" : "按微信多选数据中的同一消息关联") → images/\(file)\n" }
            else { markdown += "- \(name)：未匹配（\(missing[name] ?? "未知原因")）\n" }
        }
        for warning in Set(warnings).sorted() { markdown += "- \(warning)\n" }
        let markdownFile = output.appendingPathComponent("conversation.md")
        try checkCancellation()
        try markdown.write(to: markdownFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markdownFile.path)
        try checkCancellation()
        return Result(directory: output, messages: parsed.messages.count,
                      matched: refs.filter { replacements[$0] != nil }.count,
                      unmatched: refs.filter { replacements[$0] == nil }.count, warnings: Array(Set(warnings)))
        } catch {
            let exportError = error
            do { try fm.removeItem(at: output) }
            catch {
                throw NSError(domain: "ClipHarbor.Export", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "导出未完成，且无法清理本次目录 \(output.path)：\(error.localizedDescription)"])
            }
            throw exportError
        }
    }
}
