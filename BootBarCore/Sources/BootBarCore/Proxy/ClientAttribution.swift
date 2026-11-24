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
        return Self.describe(pid: pid, executable: path)
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
