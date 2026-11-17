import AppKit
import ServiceManagement
import MoverCore
import Darwin

enum Management {
    static let identifier = "local.pritam.mycopy"

    static func runIfRequested() -> Bool {
        guard let command = CommandLine.arguments.dropFirst().first,
              ["--status", "--self-test", "--ui-self-test", "--stop", "--register-login", "--unregister-login", "--prepare-uninstall", "--prepare-test-uninstall"].contains(command) else { return false }
        do {
            switch command {
            case "--self-test":
                try SelfTest.run()
            case "--ui-self-test":
                try UISelfTest.run()
            case "--prepare-test-uninstall":
                guard CommandLine.arguments.count == 3 else { throw TransferError.unsafe("An isolated test root is required.") }
                let root = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
                guard root.path != "/", root != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath(),
                      FileManager.default.fileExists(atPath: root.appendingPathComponent(".mcopy-test-root").path) else {
                    throw TransferError.unsafe("The test root marker is missing.")
                }
                try UninstallRecovery.prepare(applicationSupport: root.appendingPathComponent("Library/Application Support"))
                print("Isolated recovery cleanup complete; login registrations were not changed.")
            case "--status":
                let values: [String: Any] = [
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    "bundlePath": Bundle.main.bundleURL.path,
                    "loginStatus": loginStatus(),
                    "runningProcesses": runningApps().map { Int($0.processIdentifier) },
                    "runningApplications": runningApps().map { application in
                        ["pid": Int(application.processIdentifier), "hidden": application.isHidden,
                         "active": application.isActive, "path": application.bundleURL?.path ?? "unknown"] as [String: Any]
                    }
                ]
                let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            case "--stop":
                try stop()
            case "--register-login":
                let status = SMAppService.mainApp.status
                if status != .enabled && status != .requiresApproval {
                    do { try SMAppService.mainApp.register() }
                    catch {
                        if SMAppService.mainApp.status != .requiresApproval { throw error }
                    }
                }
                print("Login startup: \(loginStatus())")
            case "--unregister-login":
                try unregisterLogin()
            case "--prepare-uninstall":
                try stop()
                let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
                try UninstallRecovery.prepare(applicationSupport: support)
                try unregisterLogin()
                print("Stopped mCopy, recovered unfinished transfers, and disabled login startup.")
            default: break
            }
        } catch {
            fputs("mCopy: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        return true
    }

    static func runningApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }
    }

    static func stop() throws {
        for application in runningApps() {
            guard application.terminate() else {
                throw TransferError.unsafe("Could not stop mCopy. Quit it before installing or uninstalling.")
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !runningApps().isEmpty {
            guard Date() < deadline else {
                throw TransferError.unsafe("mCopy is still waiting for a disk/network operation. Wait for it to finish, then run the command again. It was not force-killed.")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func unregisterLogin() throws {
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval { try SMAppService.mainApp.unregister() }
        print("Login startup: \(loginStatus())")
    }

    static func loginStatus() -> String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "not-registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires-approval"
        case .notFound: return "not-found"
        @unknown default: return "unknown"
        }
    }
}
