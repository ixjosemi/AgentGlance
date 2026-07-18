import Foundation

public final class CodexSessionsWatcher {
    private static let readChunkSize = 65_536
    private static let maximumLineSize = 1_048_576
    private let sessionsDirectoryURL: URL
    private let repository: StateRepository
    private let processIDResolver: @Sendable (AgentSession) -> Int32?
    private let minimumModificationDate: Date?
    private var offsets: [URL: UInt64] = [:]
    private var buffers: [URL: Data] = [:]
    private var parsers: [URL: CodexRolloutParser] = [:]

    public init(
        sessionsDirectoryURL: URL,
        repository: StateRepository,
        processID: Int32,
        minimumModificationDate: Date? = nil
    ) {
        self.sessionsDirectoryURL = sessionsDirectoryURL
        self.repository = repository
        processIDResolver = { _ in processID }
        self.minimumModificationDate = minimumModificationDate
    }

    public init(
        sessionsDirectoryURL: URL,
        repository: StateRepository,
        minimumModificationDate: Date? = nil,
        processIDResolver: @escaping @Sendable (AgentSession) -> Int32?
    ) {
        self.sessionsDirectoryURL = sessionsDirectoryURL
        self.repository = repository
        self.processIDResolver = processIDResolver
        self.minimumModificationDate = minimumModificationDate
    }

    public func scan() throws {
        for fileURL in try rolloutFileURLs() {
            try consumeNewData(from: fileURL)
        }
    }

    private func rolloutFileURLs() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else {
            return []
        }
        return enumerator.compactMap { element -> URL? in
            guard let url = element as? URL, url.pathExtension == "jsonl" else { return nil }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ]), values.isRegularFile == true, values.isSymbolicLink != true else {
                return nil
            }
            if let minimumModificationDate,
               let modificationDate = values.contentModificationDate,
               modificationDate < minimumModificationDate {
                return nil
            }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func consumeNewData(from fileURL: URL) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let previousOffset = offsets[fileURL, default: 0]
        if size < previousOffset {
            reset(fileURL)
        }
        let offset = offsets[fileURL, default: 0]
        try handle.seek(toOffset: offset)
        while let data = try handle.read(upToCount: Self.readChunkSize), !data.isEmpty {
            offsets[fileURL, default: offset] += UInt64(data.count)
            buffers[fileURL, default: Data()].append(data)
            try consumeCompleteLines(for: fileURL)
            if buffers[fileURL, default: Data()].count > Self.maximumLineSize {
                buffers[fileURL] = Data()
            }
        }
    }

    private func consumeCompleteLines(for fileURL: URL) throws {
        var buffer = buffers[fileURL, default: Data()]
        var parser = parsers[fileURL] ?? CodexRolloutParser(processID: 0)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            if line.count <= Self.maximumLineSize,
               let session = parser.consume(line: Data(line)) {
                guard let processID = processIDResolver(session) else { continue }
                try repository.save(session.replacingProcessID(processID))
            }
        }
        buffers[fileURL] = buffer
        parsers[fileURL] = parser
    }

    private func reset(_ fileURL: URL) {
        offsets[fileURL] = 0
        buffers[fileURL] = Data()
        parsers[fileURL] = CodexRolloutParser(processID: 0)
    }
}
