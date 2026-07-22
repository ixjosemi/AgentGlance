/// Platform-neutral status-indicator semantics shared by the compact bar and
/// expanded session rows. The app target translates these styles into SwiftUI
/// views while the behavioral runner can verify the user-facing state mapping.
public enum StatusIndicatorStyle: Equatable, Sendable {
    case spinner
    case mutedDot
    case greenDot
    case redDot
}

public extension SessionStatus {
    var indicatorStyle: StatusIndicatorStyle {
        switch self {
        case .working: .spinner
        case .idle: .greenDot
        case .needsAttention: .redDot
        case .ended: .mutedDot
        }
    }
}

public extension SessionStatusSummary.StatusEntry.Kind {
    var indicatorStyle: StatusIndicatorStyle {
        switch self {
        case .running: .spinner
        case .waiting: .greenDot
        case .blocked: .redDot
        }
    }
}
