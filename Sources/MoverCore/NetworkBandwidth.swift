import Foundation

// Both workers share this bucket. Changing the rate preserves earned tokens,
// so frequent adaptive updates do not keep restarting a long wait.
final class NetworkBandwidth {
    let lock = NSLock()
    var rate = 0.0
    var tokens = 0.0
    var lastTime: Double?
    let capacity = 65_536.0

    func refill(at time: Double) {
        if let lastTime { tokens = min(capacity, tokens + max(0, time - lastTime) * rate) }
        lastTime = time
    }

    func setLimitMB(_ megabytes: Double, at time: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        refill(at: time)
        rate = megabytes.isFinite && megabytes > 0 ? megabytes * 1_000_000 : 0
        if rate == 0 { tokens = 0 }
    }

    var limitMB: Double {
        lock.lock(); defer { lock.unlock() }
        return rate / 1_000_000
    }

    func take(_ remaining: Int, at time: Double) -> (bytes: Int, wait: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard rate > 0 else { return (remaining, 0) }
        refill(at: time)
        let amount = min(remaining, Int(capacity))
        if tokens >= Double(amount) {
            tokens -= Double(amount)
            return (amount, 0)
        }
        return (0, (Double(amount) - tokens) / rate)
    }
}
