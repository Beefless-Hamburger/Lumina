import Foundation

protocol HeartbeatTimerToken: AnyObject, Sendable {
    func invalidate()
}

@MainActor
protocol HeartbeatScheduling: AnyObject {
    func schedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> any HeartbeatTimerToken
}

final class FoundationHeartbeatTimerToken: HeartbeatTimerToken, @unchecked Sendable {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func invalidate() {
        timer.invalidate()
    }
}

@MainActor
final class FoundationHeartbeatScheduler: HeartbeatScheduling {
    func schedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> any HeartbeatTimerToken {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                handler()
            }
        }
        timer.tolerance = tolerance
        return FoundationHeartbeatTimerToken(timer: timer)
    }
}

@MainActor
final class ShutdownHeartbeatController {
    private let scheduler: any HeartbeatScheduling
    private let interval: TimeInterval
    private let tolerance: TimeInterval
    private var timer: (any HeartbeatTimerToken)?

    init(
        scheduler: any HeartbeatScheduling = FoundationHeartbeatScheduler(),
        interval: TimeInterval = 900,
        tolerance: TimeInterval = 60
    ) {
        self.scheduler = scheduler
        self.interval = interval
        self.tolerance = tolerance
    }

    var isRunning: Bool {
        timer != nil
    }

    func start(handler: @escaping @MainActor @Sendable () -> Void) {
        guard timer == nil else { return }

        timer = scheduler.schedule(interval: interval, tolerance: tolerance) { [weak self] in
            guard self?.timer != nil else { return }
            handler()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
