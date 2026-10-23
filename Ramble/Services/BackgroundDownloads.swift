import Foundation
import OSLog

/// A file in a Hugging Face repository.
nonisolated struct RemoteFile: Codable, Equatable, Sendable {
    /// Path inside the repository, which is also where it goes inside the job's folder.
    let path: String
    let size: Int64
    let url: URL
}

/// Large model downloads that keep going while the screen is off, the person is in another
/// app, or iOS has closed this one: the system's background download service does the work,
/// and files are moved into place as each one finishes. Jobs are remembered across launches.
nonisolated final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloads()
    static let identifier = "com.zengji.suikouji.downloads"
    /// Posted on the main queue with the job id as `object` when a job's progress or state changes.
    static let didChange = Notification.Name("BackgroundDownloads.didChange")

    enum JobState: Equatable {
        case none, running(Double), finished, failed(String)
    }

    private struct Job: Codable {
        /// Relative to the app's home folder, which moves when the app is updated.
        let folder: String
        let files: [RemoteFile]
        var failure: String?
    }

    private let lock = NSLock()
    private var jobs: [String: Job]
    /// Bytes written so far by each running task, by job.
    private var written: [Int: (job: String, bytes: Int64)] = [:]
    private var retries: [String: Int] = [:]
    private var lastNotice: [String: Date] = [:]
    private var eventsFinished: (() -> Void)?
    /// Events can finish before the scene asks to wait for them.
    private var eventsAlreadyFinished = false
    private let log = Logger(subsystem: "com.zengji.suikouji", category: "downloads")
    private static let jobsKey = "downloads.jobs"

    private var storedSession: URLSession?

    /// Created on first use: iOS allows one session per identifier, and it must be the one that
    /// reconnects to downloads started in an earlier launch.
    private var session: URLSession {
        lock.withLock {
            if let storedSession { return storedSession }
            let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
            // Models are 1–2 GB: Wi‑Fi (or wired) only, never a cellular plan or a hotspot. A
            // download started without Wi‑Fi waits for it rather than failing.
            configuration.allowsCellularAccess = false
            configuration.allowsExpensiveNetworkAccess = false
            configuration.allowsConstrainedNetworkAccess = false
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            storedSession = session
            return session
        }
    }

    override private init() {
        jobs = (UserDefaults.standard.data(forKey: Self.jobsKey))
            .flatMap { try? JSONDecoder().decode([String: Job].self, from: $0) } ?? [:]
        super.init()
    }

    /// Reconnects to downloads that were running when the app was last closed.
    func resume() {
        _ = session
    }

    // MARK: Jobs

    /// Downloads every file of `files` that isn't already in `folder`.
    func start(job id: String, folder: URL, files: [RemoteFile]) {
        let relative = Self.relative(folder)
        lock.withLock {
            jobs[id] = Job(folder: relative, files: files, failure: nil)
            retries[id] = 0
            save()
        }
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap(\.taskDescription))
            for file in files where !Self.isComplete(file, in: folder) {
                let description = Self.describe(job: id, path: file.path)
                guard !running.contains(description) else { continue }
                let task = self.session.downloadTask(with: file.url)
                task.taskDescription = description
                task.countOfBytesClientExpectsToReceive = file.size
                task.resume()
            }
            self.notify(id, force: true)
        }
    }

    func cancel(job id: String) {
        lock.withLock {
            jobs[id] = nil
            save()
        }
        session.getAllTasks { tasks in
            tasks.filter { Self.parse($0.taskDescription)?.job == id }.forEach { $0.cancel() }
            self.notify(id, force: true)
        }
    }

    func state(of id: String) -> JobState {
        lock.withLock {
            guard let job = jobs[id] else { return .none }
            if let failure = job.failure { return .failed(failure) }
            let folder = Self.absolute(job.folder)
            let total = job.files.reduce(Int64(0)) { $0 + $1.size }
            var done: Int64 = 0
            var complete = true
            for file in job.files {
                if Self.isComplete(file, in: folder) {
                    done += file.size
                } else {
                    complete = false
                }
            }
            if complete { return .finished }
            let inFlight = written.values.filter { $0.job == id }.reduce(Int64(0)) { $0 + $1.bytes }
            return .running(total > 0 ? min(0.99, Double(done + inFlight) / Double(total)) : 0)
        }
    }

    /// Forgets a finished job (its files stay).
    func forget(job id: String) {
        lock.withLock {
            jobs[id] = nil
            save()
        }
    }

    /// Called from the scene's background task when iOS wakes the app for download events.
    func handleBackgroundEvents() async {
        resume()
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if eventsAlreadyFinished {
                    eventsAlreadyFinished = false
                    return true
                }
                eventsFinished = { continuation.resume() }
                return false
            }
            if done { continuation.resume() }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, _) = Self.parse(downloadTask.taskDescription) else { return }
        lock.withLock { written[downloadTask.taskIdentifier] = (id, totalBytesWritten) }
        notify(id)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, path) = Self.parse(downloadTask.taskDescription) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            fail(id, String(localized: "下载失败（服务器返回 \(status)）。"))
            return
        }
        guard let folder = lock.withLock({ jobs[id].map { Self.absolute($0.folder) } }) else { return }
        // The temporary file is deleted when this returns, so move it now.
        let destination = folder.appending(path: path)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (id, _) = Self.parse(task.taskDescription) else { return }
        lock.withLock { written[task.taskIdentifier] = nil }
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            log.error("Download failed: \(error.localizedDescription, privacy: .public)")
            // Pick up where it stopped, a few times, before giving up.
            let attempt = lock.withLock { () -> Int in
                retries[id, default: 0] += 1
                return retries[id] ?? 0
            }
            if attempt <= 5, let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                let retry = session.downloadTask(withResumeData: data)
                retry.taskDescription = task.taskDescription
                retry.resume()
            } else if attempt <= 5, let url = task.originalRequest?.url {
                let retry = session.downloadTask(with: url)
                retry.taskDescription = task.taskDescription
                retry.resume()
            } else {
                fail(id, error.localizedDescription)
            }
        }
        notify(id, force: true)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let finished = lock.withLock { () -> (() -> Void)? in
            defer { eventsFinished = nil }
            if eventsFinished == nil { eventsAlreadyFinished = true }
            return eventsFinished
        }
        DispatchQueue.main.async { finished?() }
    }

    // MARK: Helpers

    private func fail(_ id: String, _ message: String) {
        lock.withLock {
            jobs[id]?.failure = message
            save()
        }
        session.getAllTasks { tasks in
            tasks.filter { Self.parse($0.taskDescription)?.job == id }.forEach { $0.cancel() }
        }
        notify(id, force: true)
    }

    /// At most a few progress updates a second.
    private func notify(_ id: String, force: Bool = false) {
        let now = Date.now
        let send = lock.withLock { () -> Bool in
            if !force, let last = lastNotice[id], now.timeIntervalSince(last) < 0.3 { return false }
            lastNotice[id] = now
            return true
        }
        guard send else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: id)
        }
    }

    /// Caller holds the lock.
    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(jobs), forKey: Self.jobsKey)
    }

    static func isComplete(_ file: RemoteFile, in folder: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: file.path).path)[.size] as? Int64) ?? -1
        return size == file.size
    }

    private static func describe(job: String, path: String) -> String {
        job + "\n" + path
    }

    static func parse(_ description: String?) -> (job: String, path: String)? {
        guard let parts = description?.split(separator: "\n", maxSplits: 1), parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func relative(_ folder: URL) -> String {
        let home = URL.homeDirectory.standardizedFileURL.path + "/"
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
    }

    private static func absolute(_ stored: String) -> URL {
        stored.hasPrefix("/") ? URL(filePath: stored, directoryHint: .isDirectory)
                              : URL.homeDirectory.appending(path: stored, directoryHint: .isDirectory)
    }
}

/// Lists a Hugging Face repository's files (or one folder of it) with their sizes.
nonisolated enum HuggingFaceFiles {
    static func list(repo: String, folder: String = "") async throws -> [RemoteFile] {
        var path = "https://huggingface.co/api/models/\(repo)/tree/main"
        if !folder.isEmpty { path += "/" + folder }
        var next: URL? = URL(string: path + "?recursive=true")
        var files: [RemoteFile] = []
        while let url = next {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OpenModelError.badRepository }
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            for entry in entries where entry.type == "file" {
                let encoded = entry.path.split(separator: "/")
                    .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                    .joined(separator: "/")
                guard let fileURL = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)") else { continue }
                files.append(RemoteFile(path: entry.path, size: entry.size ?? 0, url: fileURL))
            }
            next = nextPage(response)
        }
        return files
    }

    private struct Entry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    /// The tree API pages long listings with a `Link: <…>; rel="next"` header.
    private static func nextPage(_ response: URLResponse) -> URL? {
        guard let link = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link"),
              let match = link.firstMatch(of: #/<([^>]+)>;\s*rel="next"/#) else { return nil }
        return URL(string: String(match.1))
    }
}

extension FileManager {
    /// Disk space the files in `folder` take, subfolders included; 0 if it doesn't exist.
    nonisolated func allocatedBytes(in folder: URL) -> Int64 {
        let enumerator = enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
