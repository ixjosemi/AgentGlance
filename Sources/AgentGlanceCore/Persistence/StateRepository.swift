import Foundation
import Darwin

public enum StateRepositoryError: Error, Equatable, Sendable {
    case insecureDirectory
    case sessionIdentifierTooLong
}

public struct StateRepository: Sendable {
    private static let maximumStateFileSize = 1_048_576
    private static let maximumSessionIdentifierBytes = 128
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func prepareDirectory() throws {
        try ensurePrivateDirectory()
    }

    public func loadSessions() throws -> [AgentSession] {
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try ensurePrivateDirectory()
        }
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        var sessions: [AgentSession] = []
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            do {
                sessions.append(try AgentSession.decode(from: secureData(at: fileURL)))
            } catch {
                continue
            }
        }
        return sessions
    }

    public func save(_ session: AgentSession) throws {
        try prepareDirectory()
        if session.source != .reaper {
            let supersededSessions = try loadSessions().filter {
                let isFallback = $0.source == .reaper
                    && $0.tool == session.tool
                    && $0.pid == session.pid
                let isOlderCodexCorrelation = session.tool == .codex
                    && $0.tool == .codex
                    && $0.pid == session.pid
                    && $0.sessionID != session.sessionID
                return isFallback || isOlderCodexCorrelation
            }
            for supersededSession in supersededSessions {
                try remove(supersededSession)
            }
        }
        let destinationURL = directoryURL.appendingPathComponent(try fileName(for: session))
        let temporaryURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )

        guard Darwin.rename(temporaryURL.path, destinationURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        StateChangeNotifier.post()
    }

    public func remove(_ session: AgentSession) throws {
        let fileURL = directoryURL.appendingPathComponent(try fileName(for: session))
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private func fileName(for session: AgentSession) throws -> String {
        let identifierData = Data(session.sessionID.utf8)
        guard identifierData.count <= Self.maximumSessionIdentifierBytes else {
            throw StateRepositoryError.sessionIdentifierTooLong
        }
        let encodedIdentifier = identifierData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(session.tool.rawValue)-\(encodedIdentifier).json"
    }

    private func ensurePrivateDirectory() throws {
        var metadata = stat()
        if Darwin.lstat(directoryURL.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid() else {
                throw StateRepositoryError.insecureDirectory
            }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.chmod(directoryURL.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func secureData(at fileURL: URL) throws -> Data {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumStateFileSize else {
            throw StateRepositoryError.insecureDirectory
        }
        return try handle.readToEnd() ?? Data()
    }
}
