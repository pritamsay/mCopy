import Foundation

public struct WiFiTraffic {
    public var nasBytes: Int64
    public var otherBytes: Int64
    public var hasNASConnection: Bool

    public init(nasBytes: Int64, otherBytes: Int64, hasNASConnection: Bool) {
        self.nasBytes = nasBytes
        self.otherBytes = otherBytes
        self.hasNASConnection = hasNASConnection
    }
}

public struct InternetAllowance {
    public var limitMB: Double
    public var internetActive: Bool
}

public struct InternetPriority {
    var idleCapacity = 0.0
    var activeCapacity = 0.0
    var lastActivity = -Double.infinity
    var demand = 0.0
    var startupSamples = 0

    public init() {}

    public mutating func update(_ traffic: WiFiTraffic, seconds: Double, at time: Double) -> InternetAllowance {
        let duration = max(0.1, seconds)
        let nas = Double(max(0, traffic.nasBytes)) / duration
        let other = Double(max(0, traffic.otherBytes)) / duration
        let bulkNAS = nas >= 65_536
        if other >= 65_536 { lastActivity = time }
        let busy = time - lastActivity < 3
        guard busy else {
            if bulkNAS { idleCapacity = max(nas, idleCapacity * 0.98) }
            activeCapacity = 0
            demand = 0
            return InternetAllowance(limitMB: 0, internetActive: false)
        }
        demand = max(other, demand * 0.7)
        // Starting while a browser is already active must not teach the policy
        // that tiny background traffic is the Wi-Fi link's entire capacity.
        if bulkNAS { startupSamples += 1 }
        activeCapacity = max(activeCapacity, idleCapacity, bulkNAS ? nas + other : 0)
        if idleCapacity == 0 && startupSamples < 2 {
            return InternetAllowance(limitMB: 0, internetActive: busy)
        }
        guard traffic.hasNASConnection, activeCapacity > 0 else {
            return InternetAllowance(limitMB: 0, internetActive: true)
        }
        // Reserve Wi-Fi headroom and back off further as other traffic grows.
        let allowance = max(activeCapacity * 0.01, activeCapacity * 0.75 - demand * 1.5)
        return InternetAllowance(limitMB: allowance / 1_000_000, internetActive: true)
    }
}

// nettop's CSV contains a header for every snapshot. Only socket rows on Wi-Fi
// count; per-process totals would double-count them. No endpoints are retained.
public struct WiFiTrafficParser {
    var incoming: Int?
    var outgoing: Int?
    var interface: Int?
    var haveHeader = false
    var skipFirst = true
    var nas: Int64 = 0
    var other: Int64 = 0
    var hasNAS = false

    public init() {}

    // Finite nettop logging ends after its last rows, without another header.
    public mutating func finish() -> WiFiTraffic? {
        guard haveHeader, !skipFirst else { return nil }
        haveHeader = false
        return WiFiTraffic(nasBytes: nas, otherBytes: other, hasNASConnection: hasNAS)
    }

    public mutating func consume(_ line: String) -> WiFiTraffic? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let name = fields.first else { return nil }
        if name.isEmpty && fields.contains("bytes_in") {
            let completed = haveHeader ? WiFiTraffic(nasBytes: nas, otherBytes: other, hasNASConnection: hasNAS) : nil
            incoming = fields.firstIndex(of: "bytes_in")
            outgoing = fields.firstIndex(of: "bytes_out")
            interface = fields.firstIndex(of: "interface")
            haveHeader = true
            nas = 0; other = 0; hasNAS = false
            if completed != nil && skipFirst { skipFirst = false; return nil }
            return completed
        }
        let socket = name.trimmingCharacters(in: .whitespaces)
        guard socket.hasPrefix("tcp") || socket.hasPrefix("udp"),
              let incoming, let outgoing, let interface,
              fields.indices.contains(incoming), fields.indices.contains(outgoing), fields.indices.contains(interface),
              !fields[interface].isEmpty else { return nil }
        let bytes = max(0, Int64(fields[incoming]) ?? 0) + max(0, Int64(fields[outgoing]) ?? 0)
        let endpoints = socket.components(separatedBy: "<->")
        let ports = endpoints.compactMap { Int($0.components(separatedBy: ":").last ?? "") }
        let storage = ports.contains { [139, 445, 548, 2049].contains($0) }
        if storage { nas += bytes; hasNAS = true }
        else { other += bytes }
        return nil
    }
}
