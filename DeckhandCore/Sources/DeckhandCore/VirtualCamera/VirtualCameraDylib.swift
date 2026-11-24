import CryptoKit
import Foundation

public enum VirtualCameraDylibError: LocalizedError, Equatable, CustomStringConvertible {
    case notFound
    case install(String)

    public var description: String {
        switch self {
        case .notFound:
            "The simulator camera needs Baguette's VirtualCamera library. Install it with: brew install baguette"
        case .install(let reason):
            "Could not install the camera library: \(reason)"
        }
    }
}

/// Finds Baguette's `VirtualCamera.dylib` and keeps a private copy keyed by content hash. The simulator's dyld
/// rejects a replaced dylib at an unchanged path, so each version must live at its own path.
public struct VirtualCameraDylib: Sendable {
    public static let fileName = "VirtualCamera.dylib"

    private let candidates: @Sendable () -> [String]
    private let supportDirectory: String

    public init(supportDirectory: String = NSHomeDirectory() + "/Library/Application Support/Deckhand/VirtualCamera",
                candidates: @escaping @Sendable () -> [String] = VirtualCameraDylib.defaultCandidates) {
        self.supportDirectory = supportDirectory
        self.candidates = candidates
    }

    public static let defaultCandidates: @Sendable () -> [String] = {
        let manager = FileManager.default
        var found: [String] = []
        if let override = ProcessInfo.processInfo.environment["DECKHAND_VIRTUAL_CAMERA_DYLIB"] { found.append(override) }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            found.append("\(prefix)/opt/baguette/libexec/Baguette_Baguette.bundle/Contents/Resources/VirtualCamera/\(fileName)")
        }
        // builds Baguette itself installed, newest first
        let builds = NSHomeDirectory() + "/Library/Application Support/Baguette/builds"
        let installed = ((try? manager.contentsOfDirectory(atPath: builds)) ?? [])
            .map { "\(builds)/\($0)/\(fileName)" }
            .filter { manager.fileExists(atPath: $0) }
            .sorted {
                let first = (try? manager.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
                let second = (try? manager.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
                return first > second
            }
        return found + installed
    }

    /// The path to inject: a copy of the first library found, at `<support>/<hash>/VirtualCamera.dylib`.
    public func install() throws -> String {
        guard let source = candidates().first(where: { FileManager.default.isReadableFile(atPath: $0) }) else {
            throw VirtualCameraDylibError.notFound
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            let hash = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
            let directory = "\(supportDirectory)/\(hash)"
            let destination = "\(directory)/\(Self.fileName)"
            if !FileManager.default.fileExists(atPath: destination) {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                // copied byte for byte: the simulator accepts the linker's ad-hoc signature but not a re-signed file
                try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
            }
            return destination
        } catch {
            throw VirtualCameraDylibError.install(error.localizedDescription)
        }
    }

    public var isAvailable: Bool {
        candidates().contains { FileManager.default.isReadableFile(atPath: $0) }
    }
}

extension VirtualCameraDylibError {
    public var errorDescription: String? { description }
}
