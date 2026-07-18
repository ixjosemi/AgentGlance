import Foundation
import Observation
import Darwin
import CoreFoundation

public struct StateObservationLayers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let darwinNotification = StateObservationLayers(rawValue: 1 << 0)
    public static let fileSystem = StateObservationLayers(rawValue: 1 << 1)
    public static let polling = StateObservationLayers(rawValue: 1 << 2)
    public static let all: StateObservationLayers = [
        .darwinNotification,
        .fileSystem,
        .polling,
    ]
}

private let stateStoreNotificationCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else { return }
    let store = Unmanaged<StateStore>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async { store.reloadRecordingError() }
}

@Observable
public final class StateStore {
    public private(set) var sessions: [AgentSession] = []
    public private(set) var lastErrorDescription: String?

    private let repository: StateRepository
    private var pollingTimer: Timer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var observesDarwinNotifications = false

    public init(repository: StateRepository) {
        self.repository = repository
    }

    public func reload() throws {
        let loadedSessions = try repository.loadSessions()
        for session in loadedSessions where session.status == .ended {
            try repository.remove(session)
        }
        sessions = loadedSessions
            .filter { $0.status != .ended }
            .sorted(by: Self.precedes)
    }

    public func sessions(for tool: AgentTool) -> [AgentSession] {
        sessions.filter { $0.tool == tool }
    }

    public func startObserving(
        pollInterval: TimeInterval? = 5,
        layers: StateObservationLayers = .all
    ) throws {
        stopObserving()
        try repository.prepareDirectory()
        try reload()
        if layers.contains(.darwinNotification) {
            startDarwinObservation()
        }
        if layers.contains(.fileSystem) {
            try startDirectoryObservation()
        }
        if layers.contains(.polling), let pollInterval {
            pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
                [weak self] _ in
                self?.reloadRecordingError()
            }
        }
    }

    public func stopObserving() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        directorySource?.cancel()
        directorySource = nil
        if observesDarwinNotifications {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(StateChangeNotifier.notificationName as CFString),
                nil
            )
            observesDarwinNotifications = false
        }
    }

    private func startDarwinObservation() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            stateStoreNotificationCallback,
            StateChangeNotifier.notificationName as CFString,
            nil,
            .deliverImmediately
        )
        observesDarwinNotifications = true
    }

    private func startDirectoryObservation() throws {
        let descriptor = Darwin.open(repository.directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.reloadRecordingError() }
        source.setCancelHandler { Darwin.close(descriptor) }
        directorySource = source
        source.resume()
    }

    fileprivate func reloadRecordingError() {
        do {
            try reload()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = String(describing: error)
        }
    }

    private static func precedes(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        let rank: [SessionStatus: Int] = [.needsAttention: 0, .working: 1, .idle: 2, .ended: 3]
        let leftRank = rank[lhs.status, default: 3]
        let rightRank = rank[rhs.status, default: 3]
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}
