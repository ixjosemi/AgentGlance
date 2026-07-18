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
    DispatchQueue.main.async { store.scheduleCoalescedReload() }
}

@Observable
public final class StateStore {
    public private(set) var sessions: [AgentSession] = []
    public private(set) var lastErrorDescription: String?
    public private(set) var acknowledgments = AttentionAcknowledgments()

    private let repository: StateRepository
    private var pollingTimer: Timer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var observesDarwinNotifications = false
    private var reloadScheduled = false

    public init(repository: StateRepository) {
        self.repository = repository
    }

    /// Reloading is strictly a read: ended sessions are filtered from the UI
    /// but their files stay on disk for the reaper to delete on its own
    /// queue. A reload that writes would re-trigger this store's directory
    /// observation and feed back into itself.
    public func reload() throws {
        sessions = try repository.loadSessions()
            .filter { $0.status != .ended }
            .sorted(by: Self.precedes)
        acknowledgments.prune(keeping: sessions)
    }

    public func sessions(for tool: AgentTool) -> [AgentSession] {
        sessions.filter { $0.tool == tool }
    }

    /// Marks a waiting session as visited so the bar semaphore goes quiet
    /// until the session shows new activity.
    public func acknowledge(_ session: AgentSession) {
        acknowledgments.acknowledge(session)
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
        source.setEventHandler { [weak self] in self?.scheduleCoalescedReload() }
        source.setCancelHandler { Darwin.close(descriptor) }
        directorySource = source
        source.resume()
    }

    /// Coalesces bursts of directory events into one reload per 150ms window
    /// so that an aggressive writer — another process, or a misbehaving
    /// integration — can never storm the main thread with reloads.
    fileprivate func scheduleCoalescedReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reloadRecordingError()
        }
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
