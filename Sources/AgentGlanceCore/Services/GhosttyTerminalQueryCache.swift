import Foundation

/// Caches the answer to "which terminals does Ghostty show right now".
/// Each query spawns osascript (~50 ms of CPU) and makes Ghostty service
/// Apple Events, so the observation heartbeat must not pay for it on every
/// tick. The cache refreshes immediately when the set of Ghostty-hosted
/// agent processes changes — a new session needs its terminal right away —
/// and otherwise ages out on a TTL that keeps tab titles reasonably fresh.
/// Failed queries are never cached: a scan without terminal data should be
/// retried on the next tick, exactly as before the cache existed.
public final class GhosttyTerminalQueryCache: @unchecked Sendable {
    private let timeToLive: TimeInterval
    private let query: @Sendable () -> [GhosttyTerminal]?
    private let lock = NSLock()
    private var cachedTerminals: [GhosttyTerminal]?
    private var cachedProcessIDs: Set<pid_t> = []
    private var refreshedAt: Date = .distantPast

    public init(
        timeToLive: TimeInterval,
        query: @escaping @Sendable () -> [GhosttyTerminal]?
    ) {
        self.timeToLive = timeToLive
        self.query = query
    }

    public func terminals(
        hostingProcessIDs processIDs: Set<pid_t>,
        now: Date = Date()
    ) -> [GhosttyTerminal]? {
        lock.lock()
        if let cachedTerminals,
           processIDs == cachedProcessIDs,
           now.timeIntervalSince(refreshedAt) < timeToLive {
            lock.unlock()
            return cachedTerminals
        }
        lock.unlock()
        guard let refreshed = query() else { return nil }
        lock.lock()
        cachedTerminals = refreshed
        cachedProcessIDs = processIDs
        refreshedAt = now
        lock.unlock()
        return refreshed
    }
}
