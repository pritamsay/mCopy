import Foundation

// A short moving window shows current write throughput rather than counting
// skipped files, old partial copies, or checksum reads as newly copied bytes.
public struct TransferSpeed {
    var samples: [(time: TimeInterval, bytes: Int64)] = []

    public init() {}

    public mutating func reset() { samples.removeAll() }

    public mutating func sample(bytes: Int64, at time: TimeInterval) -> Double {
        guard time.isFinite, bytes >= 0 else { return 0 }
        if let last = samples.last, time < last.time || bytes < last.bytes { reset() }
        samples.append((time, bytes))
        while samples.count > 1, samples[1].time <= time - 2 { samples.removeFirst() }
        guard let first = samples.first, time > first.time else { return 0 }
        return Double(bytes - first.bytes) / (time - first.time)
    }
}
