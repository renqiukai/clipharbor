import Foundation
import Combine

@MainActor
final class WeChatExportSession: ObservableObject {
    @Published var result: WeChatExport.Result?
    @Published var error: String?
    @Published var isTerminating = false
    @Published private(set) var working = false
    @Published private(set) var scanned = 0
    @Published private(set) var status = ""
    private var task: Task<WeChatExport.Result, Error>?
    private var taskID: UUID?
    private var cleanupFailures: [NSError] = []

    func start(_ operation: @escaping @Sendable (@escaping @Sendable (Int) -> Void) throws -> WeChatExport.Result) {
        guard task == nil, !isTerminating else { return }
        let id = UUID()
        taskID = id
        result = nil
        error = nil
        scanned = 0
        working = true
        status = "正在搜索和导出…"
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            return try operation { count in
                Task { @MainActor in
                    guard self.taskID == id else { return }
                    self.scanned = count
                }
            }
        }
        task = worker
        Task { await finish(worker, id: id) }
    }

    func cancel() {
        guard let task else { return }
        status = "正在取消…"
        task.cancel()
    }

    func cancelAndWait() async -> String? {
        if let task, let id = taskID {
            cancel()
            await finish(task, id: id)
        }
        cleanupFailures.removeAll { failure in
            guard let path = failure.userInfo[NSFilePathErrorKey] as? String else { return false }
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path)
                return false
            } catch let error as CocoaError {
                return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
            } catch { return false }
        }
        return cleanupFailures.isEmpty ? nil : cleanupFailures.map(\.localizedDescription).joined(separator: "\n")
    }

    private func finish(_ worker: Task<WeChatExport.Result, Error>, id: UUID) async {
        let outcome = await worker.result
        guard taskID == id else { return }
        switch outcome {
        case .success(let output):
            result = output
            status = ""
        case .failure(let failure) where failure is CancellationError:
            status = "已取消，本次未完成的结果已清理。"
        case .failure(let failure):
            status = "导出未完成。"
            error = "导出失败：\(failure.localizedDescription)"
            let underlying = failure as NSError
            if underlying.domain == "ClipHarbor.Export", underlying.code == 1 {
                cleanupFailures.append(underlying)
            }
        }
        task = nil
        taskID = nil
        working = false
    }
}
