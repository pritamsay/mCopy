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
        let available = min(amount, Int(tokens))
        if available > 0 {
            tokens -= Double(available)
            return (available, 0)
        }
        // Spend small amounts as they accrue, rather than waiting minutes for
        // a whole 64 KiB chunk when internet traffic reduces the allowance.
        let next = min(Double(amount), max(1, rate * 0.05))
        return (0, max(0, next - tokens) / rate)
    }
}
