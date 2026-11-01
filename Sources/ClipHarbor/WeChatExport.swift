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
}

enum WeChatExport {
    private struct CopiedMessage: Decodable {
        let text: String?
        let file: String?
    }

    static let timePattern = try! NSRegularExpression(pattern: #"^\d{4}年\d{1,2}月\d{1,2}日\s+\d{1,2}:\d{2}(?::\d{2})?$"#)
    static let imagePattern = try! NSRegularExpression(pattern: #"\[图片\][ \t]+([^\r\n]+?\.dat)(?=\s|$)"#, options: [.caseInsensitive])

    static func parse(_ text: String) -> ChatParse {
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
        let preamble = lines[..<headers[0].0].joined(separator: "\n")
        let messages = headers.indices.map { index in
            let header = headers[index]
            let end = index + 1 < headers.count ? headers[index + 1].0 : lines.count
            return ChatMessage(sender: header.1, time: header.2,
                               content: lines[(header.0 + 2)..<end].joined(separator: "\n"))
        }
        return ChatParse(messages: messages, preamble: preamble)
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

    static func export(text: String, source: URL?, destination: URL, clipboardMetadata: Data? = nil) throws -> Result {
        let fm = FileManager.default
        let parsed = parse(text)
        let refs = references(in: text)
        let names = Set(refs.filter { $0 == URL(fileURLWithPath: $0).lastPathComponent && $0 != "." && $0 != ".." })
        var candidates: [String: [URL]] = [:]
        var warnings: [String] = []
        var direct: [String: URL] = [:]
        if let source, let metadata = clipboardMetadata, metadata.count <= 10_000_000,
           let messages = try? JSONDecoder().decode([CopiedMessage].self, from: metadata) {
            let root = source.standardizedFileURL.resolvingSymlinksInPath()
            var associations: [String: [URL]] = [:]
            for message in messages {
                let messageRefs = references(in: message.text ?? "")
                guard messageRefs.count == 1, let name = messageRefs.first,
                      refs.filter({ $0 == name }).count == 1, names.contains(name),
                      let path = message.file, path.hasPrefix("/") else { continue }
                let file = URL(fileURLWithPath: path).standardizedFileURL
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
                associations[name, default: []].append(file)
            }
            let repeatedPaths = Dictionary(grouping: associations.values.flatMap { $0 }, by: { $0.resolvingSymlinksInPath() })
            for (name, urls) in associations where urls.count == 1 && repeatedPaths[urls[0].resolvingSymlinksInPath()]?.count == 1 {
                direct[name] = urls[0]
            }
        }
        let namesToSearch = names.subtracting(direct.keys)
        if let source, !namesToSearch.isEmpty {
            let root = source.standardizedFileURL.resolvingSymlinksInPath()
            let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in
                warnings.append("有目录无法读取，搜索结果可能不完整；未自动匹配图片。")
                return true
            })
            guard let enumerator else { throw CocoaError(.fileReadNoPermission) }
            for case let url as URL in enumerator where namesToSearch.contains(url.lastPathComponent) {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                    warnings.append("有文件无法检查，搜索结果可能不完整；未自动匹配图片。")
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
                candidates[url.lastPathComponent, default: []].append(url)
            }
        }
        let output = destination.appendingPathComponent("微信聊天-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let images = output.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var replacements: [String: String] = [:]
        var missing: [String: String] = [:]
        for name in Set(refs).sorted() {
            guard names.contains(name) else { missing[name] = "文件名包含路径，未自动匹配"; continue }
            guard source != nil else { missing[name] = "未选择图片搜索目录"; continue }
            guard direct[name] != nil || warnings.isEmpty else { missing[name] = "搜索不完整，无法确认唯一性"; continue }
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
        if parsed.messages.isEmpty {
            markdown += "无法识别消息头，以下保留原始文本。\n\n" + render(text) + "\n"
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
        try markdown.write(to: markdownFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markdownFile.path)
        return Result(directory: output, messages: parsed.messages.count,
                      matched: refs.filter { replacements[$0] != nil }.count,
                      unmatched: refs.filter { replacements[$0] == nil }.count, warnings: Array(Set(warnings)))
    }
}
