import Foundation
import MoverCore

struct InternetPriorityStatus {
    var available = false
    var active = false
    var limitMB = 0.0
}

// Apple's built-in nettop supplies passive Wi-Fi socket counters. Only totals
// are kept; no packet contents, URLs, hosts or process histories are recorded.
final class InternetPriorityMonitor {
    let lock = NSLock()
    weak var engine: TransferEngine?
    var process: Process?
    var generation = 0
    var status = InternetPriorityStatus()
    var lastSample = 0.0

    func start(for engine: TransferEngine) {
        stop()
        lock.lock()
        self.engine = engine
        let token = generation
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.readCounters(token: token) }
    }

    func stop() {
        lock.lock()
        generation += 1
        let old = process
        let oldEngine = engine
        process = nil
        engine = nil
        status = InternetPriorityStatus()
        lock.unlock()
        if old?.isRunning == true { old?.terminate() }
        oldEngine?.networkLimitMB = 0
    }

    func currentStatus() -> InternetPriorityStatus {
        lock.lock()
        let stale = ProcessInfo.processInfo.systemUptime - lastSample > 5
        let current = stale ? engine : nil
        let result = stale ? InternetPriorityStatus() : status
        current?.networkLimitMB = 0
        lock.unlock()
        return result
    }

    static func selfTest() throws {
        let monitor = InternetPriorityMonitor()
        let engine = TransferEngine(journal: FileManager.default.temporaryDirectory.appendingPathComponent("mcopy-passive-check.json"))
        monitor.start(for: engine)
        defer { monitor.stop() }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if monitor.currentStatus().available {
                print("PASS: passive Wi-Fi counters parsed; no speed test, packet contents or endpoints recorded.")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw TransferError.unavailable("macOS passive Wi-Fi monitoring is unavailable.")
    }

    func readCounters(token: Int) {
        var policy = InternetPriority()
        while true {
            lock.lock()
            let current = token == generation
            lock.unlock()
            guard current else { return }
            let started = ProcessInfo.processInfo.systemUptime
            let traffic = readSnapshot(token: token)
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            guard token == generation else { lock.unlock(); return }
            if let traffic {
                let allowance = policy.update(traffic, seconds: max(1, now - started), at: now)
                status = InternetPriorityStatus(available: true, active: allowance.internetActive, limitMB: allowance.limitMB)
                lastSample = now
                engine?.networkLimitMB = allowance.limitMB
            } else {
                status = InternetPriorityStatus()
                engine?.networkLimitMB = 0
            }
            lock.unlock()
            // A failing utility must not turn into a tight process-spawn loop.
            if traffic == nil { Thread.sleep(forTimeInterval: 1) }
        }
    }

    func readSnapshot(token: Int) -> WiFiTraffic? {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // Two samples give one fresh delta. Ending the command flushes CSV
        // output even when quiet traffic would leave an endless pipe buffered.
        task.arguments = ["-n", "-x", "-d", "-L", "2", "-s", "1", "-t", "wifi", "-J", "interface,bytes_in,bytes_out"]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        lock.lock()
        guard token == generation else { lock.unlock(); return nil }
        process = task
        do { try task.run() }
        catch { process = nil; lock.unlock(); return nil }
        lock.unlock()
        var parser = WiFiTrafficParser()
        var pending = Data()
        var oversized = false
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                _ = parser.consume(line)
            }
            if pending.count > 1_048_576 { oversized = true; break }
        }
        lock.lock()
        let current = token == generation
        if current { process = nil }
        lock.unlock()
        if oversized, task.isRunning { task.terminate() }
        task.waitUntilExit()
        guard current, task.terminationStatus == 0, pending.count <= 1_048_576 else { return nil }
        if !pending.isEmpty { _ = parser.consume(String(decoding: pending, as: UTF8.self)) }
        return parser.finish()
    }
}
