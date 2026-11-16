import Foundation

extension TransferEngine {
    func beforeIO() throws {
        while true {
            try checkStop()
            networkLock.lock()
            let remaining = networkQuietUntil.timeIntervalSinceNow
            networkLock.unlock()
            if remaining <= 0 { return }
            Thread.sleep(forTimeInterval: min(0.1, remaining))
        }
    }

    func wait(_ seconds: Double) throws {
        let end = Date().addingTimeInterval(seconds)
        while end.timeIntervalSinceNow > 0 {
            try checkStop()
            Thread.sleep(forTimeInterval: min(0.1, max(0, end.timeIntervalSinceNow)))
        }
    }

    func retryNetwork(job: Job, index: Int, work: () throws -> Void) throws {
        var attempt = 0
        while true {
            try beforeIO()
            do {
                try work()
                return
            } catch {
                let network = job.destination.network || job.entries[index].source.network
                guard shouldRetry(error, network: network) else { throw error }
                attempt += 1
                let delay = min(maximumRetrySeconds, retrySeconds * pow(2, Double(min(attempt - 1, 5))))
                onReconnect("NAS busy or disconnected. Waiting \(Int(delay)) seconds before checking it again.")
                networkLock.lock()
                networkQuietUntil = max(networkQuietUntil, Date().addingTimeInterval(delay))
                networkLock.unlock()
                try beforeIO()
                // Two successful probes, separated in time, avoid restarting a
                // transfer at the first instant a flapping share reappears.
                var stable = 0
                while stable < 2 {
                    try checkStop()
                    do {
                        try networkProbe?(index)
                        stateLock.lock()
                        let current = activeJob ?? job
                        stateLock.unlock()
                        let destination = try current.destination.resolve()
                        try FileAccess.requireDirectory(destination)
                        let source = try current.entries[index].source.resolve()
                        let state = current.entries[index].state
                        if state != "committed" && state != "done" { _ = try FileAccess.status(source) }
                        stable += 1
                        if stable < 2 { try wait(stabilityProbeSeconds) }
                    } catch {
                        guard shouldRetry(error, network: network) else { throw error }
                        stable = 0
                        onReconnect("Waiting for the NAS connection to stay available.")
                        try wait(delay)
                    }
                }
            }
        }
    }
}
