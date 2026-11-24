import Darwin
import Foundation

public protocol ClientAttributing: Sendable {
    /// The process that owns the connection whose local port is `port`.
    func client(forLocalPort port: Int) -> ClientInfo
}

/// Finds the process behind a loopback connection with `lsof`, then names it from its executable.
public struct LsofAttribution: ClientAttributing {
    public init() {}

    public func client(forLocalPort port: Int) -> ClientInfo {
        guard let pid = owningPid(ofPort: port), let path = executablePath(of: pid) else { return .unknown }
        var info = Self.describe(pid: pid, executable: path)
        if info.deviceId == nil { info.deviceId = Self.simulatorUDID(ofProcess: pid) }
        return info
    }

    private static let cache = NSLock()
    nonisolated(unsafe) private static var simulatorByPid: [Int: String?] = [:]

    /// The simulator a process runs in. System daemons live in the runtime's own volume, so their path says nothing;
    /// their parent chain ends at that simulator's `launchd_sim`, whose arguments name the device.
    static func simulatorUDID(ofProcess pid: Int) -> String? {
        if let known = cache.withLock({ simulatorByPid[pid] }) { return known }
        var found: String?
        var current = Int32(pid)
        for _ in 0..<8 where current > 1 {
            if let udid = udid(inArguments: arguments(of: current)) {
                found = udid
                break
            }
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
            current = Int32(info.pbi_ppid)
        }
        cache.withLock { simulatorByPid[pid] = .some(found) }
        return found
    }

    static func udid(inArguments arguments: [String]) -> String? {
        for argument in arguments {
            let components = argument.split(separator: "/").map(String.init)
            if let index = components.firstIndex(of: "Devices"), index + 1 < components.count, components[index + 1].count == 36,
               arguments.contains(where: { $0.contains("launchd_sim") || $0.contains("CoreSimulator") }) {
                return components[index + 1]
            }
        }
        return nil
    }

    /// The argument vector of a process, read without spawning anything.
    static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)
        var parts: [String] = []
        var index = MemoryLayout<Int32>.size
        // skip the executable path and the padding after it
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        while parts.count < Int(argc), index < size {
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            parts.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return parts
    }

    private func owningPid(ofPort port: Int) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:ESTABLISHED", "-Fp"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let ours = Int(getpid())
        // the proxy's own end of the connection is listed as well
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { $0.hasPrefix("p") ? Int($0.dropFirst()) : nil }
            .first { $0 != ours }
    }

    private func executablePath(of pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Names a process: the app bundle it lives in, the Android tool it is, or its executable.
    public static func describe(pid: Int, executable: String) -> ClientInfo {
        var info = ClientInfo(pid: pid, executable: executable)
        let components = executable.split(separator: "/").map(String.init)
        let last = components.last ?? executable
        if let bundle = components.last(where: { $0.hasSuffix(".app") }) {
            info.app = String(bundle.dropLast(".app".count))
        } else if last == "adb" {
            info.app = "Android (adb)"
        } else if last.hasPrefix("qemu-system") || last.hasPrefix("emulator") {
            info.app = "Android emulator"
        } else {
            info.app = last
        }
        // /…/CoreSimulator/Devices/<udid>/… tells which simulator the process belongs to
        if let index = components.firstIndex(of: "Devices"), index + 1 < components.count, components[index + 1].count == 36 {
            info.deviceId = components[index + 1]
        }
        return info
    }
}
