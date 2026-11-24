import Foundation

public struct AvdDeviceDefinition: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// Form factor tag from avdmanager (`android-wear`, …); nil for phones, tablets and foldables.
    public let tag: String?

    public init(id: String, name: String, tag: String?) {
        self.id = id
        self.name = name
        self.tag = tag
    }
}

public struct SystemImage: Identifiable, Sendable, Equatable {
    public let packageId: String
    public let apiLevel: String
    public let variant: String
    public let abi: String

    public var id: String { packageId }

    public init(apiLevel: String, variant: String, abi: String) {
        self.apiLevel = apiLevel
        self.variant = variant
        self.abi = abi
        packageId = "system-images;android-\(apiLevel);\(variant);\(abi)"
    }

    public var title: String { "API \(apiLevel) · \(variantTitle)" }

    /// Tag shared with matching device definitions; nil for handheld images.
    public var formFactorTag: String? {
        variant.hasPrefix("android-") ? variant : nil
    }

    private var variantTitle: String {
        let known = ["default": "AOSP", "google_apis": "Google APIs", "google_apis_playstore": "Google Play",
                     "google_apis_playstore_ps16k": "Google Play · 16 KB pages",
                     "google_atd": "Google ATD", "aosp_atd": "AOSP ATD"]
        return known[variant] ?? variant
    }
}

public enum AvdManagerParser {
    public static func parseDeviceDefinitions(_ output: String) -> [AvdDeviceDefinition] {
        output.components(separatedBy: "---------").compactMap { block in
            var id: String?
            var name: String?
            var tag: String?
            for rawLine in block.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("id:"), let quoted = line.split(separator: "\"").dropFirst().first {
                    id = String(quoted)
                } else if line.hasPrefix("Name:") {
                    name = line.dropFirst("Name:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("Tag") {
                    tag = line.split(separator: ":", maxSplits: 1).last
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                }
            }
            guard let id, let name else { return nil }
            return AvdDeviceDefinition(id: id, name: name, tag: tag)
        }
    }
}

public struct JavaLocator: Sendable {
    private let environment: [String: String]
    private let isExecutable: @Sendable (String) -> Bool
    private let runner: any ShellRunner

    public init(runner: any ShellRunner,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.runner = runner
        self.environment = environment
        self.isExecutable = isExecutable
    }

    /// A JAVA_HOME usable by `avdmanager`, or nil to let the script look for `java` itself.
    public func locate() async -> String? {
        var candidates = [environment["JAVA_HOME"]].compactMap { $0 }
        candidates += ["Android Studio", "Android Studio Preview"].map {
            "/Applications/\($0).app/Contents/jbr/Contents/Home"
        }
        if let found = candidates.first(where: { isExecutable($0 + "/bin/java") }) { return found }
        let fromSystem = try? await runner.run("/usr/libexec/java_home", [])
        return fromSystem?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct AvdManagerService: Sendable {
    private let runner: any ShellRunner
    private let sdk: AndroidSDK
    private let java: JavaLocator
    private let isExecutable: @Sendable (String) -> Bool
    private let listDirectory: @Sendable (String) -> [String]
    private let avdHome: String
    private let readFile: @Sendable (String) -> String?
    private let writeFile: @Sendable (String, String) throws -> Void

    public init(runner: any ShellRunner, sdk: AndroidSDK,
                java: JavaLocator? = nil,
                avdHome: String = NSHomeDirectory() + "/.android/avd",
                readFile: @escaping @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
                writeFile: @escaping @Sendable (String, String) throws -> Void = {
                    try $1.write(toFile: $0, atomically: true, encoding: .utf8)
                },
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                listDirectory: @escaping @Sendable (String) -> [String] = {
                    (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
                }) {
        self.runner = runner
        self.sdk = sdk
        self.java = java ?? JavaLocator(runner: runner)
        self.isExecutable = isExecutable
        self.listDirectory = listDirectory
        self.avdHome = avdHome
        self.readFile = readFile
        self.writeFile = writeFile
    }

    public func deviceDefinitions() async throws -> [AvdDeviceDefinition] {
        AvdManagerParser.parseDeviceDefinitions(try await avdManager(["list", "device"]))
    }

    /// Installed system images, newest API first. Read from disk, so it is instant and works offline.
    public func installedSystemImages() -> [SystemImage] {
        let root = sdk.systemImagesPath
        var images: [SystemImage] = []
        for platform in listDirectory(root) where platform.hasPrefix("android-") {
            let api = String(platform.dropFirst("android-".count))
            for variant in listDirectory("\(root)/\(platform)") {
                for abi in listDirectory("\(root)/\(platform)/\(variant)") where !abi.hasPrefix(".") {
                    images.append(SystemImage(apiLevel: api, variant: variant, abi: abi))
                }
            }
        }
        return images.sorted {
            $0.apiLevel.compare($1.apiLevel, options: .numeric) == .orderedDescending
                || ($0.apiLevel == $1.apiLevel && $0.variant < $1.variant)
        }
    }

    public func create(name: String, image: SystemImage, deviceId: String,
                       options: AvdHardwareOptions = AvdHardwareOptions()) async throws {
        try Self.validate(name: name)
        var arguments = ["create", "avd", "-n", name, "-k", image.packageId, "-d", deviceId]
        if let sdCardMB = options.sdCardMB { arguments += ["--sdcard", "\(sdCardMB)M"] }
        try await avdManager(arguments)
        try applyConfiguration(options, to: name)
    }

    /// Hardware options currently stored for an existing virtual device.
    public func configuration(of name: String) -> AvdHardwareOptions? {
        readFile(configPath(name)).map(AvdConfigEditor.parse)
    }

    /// Rewrites the options that are set; everything else in `config.ini` is kept.
    public func applyConfiguration(_ options: AvdHardwareOptions, to name: String) throws {
        let entries = options.configEntries
        guard !entries.isEmpty else { return }
        guard let ini = readFile(configPath(name)) else {
            throw ShellError(command: "avd", exitCode: 1, stderr: "Could not read the configuration of \(name)")
        }
        try writeFile(configPath(name), AvdConfigEditor.merge(ini, entries: entries))
    }

    private func configPath(_ name: String) -> String { "\(avdHome)/\(name).avd/config.ini" }

    public func delete(name: String) async throws {
        try await avdManager(["delete", "avd", "-n", name])
    }

    public func rename(_ name: String, to newName: String) async throws {
        try Self.validate(name: newName)
        try await avdManager(["move", "avd", "-n", name, "-r", newName])
    }

    public static func validate(name: String) throws {
        guard name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw ShellError(command: "avdmanager", exitCode: 1,
                             stderr: "Use only letters, digits, dot, dash and underscore in the name")
        }
    }

    @discardableResult
    private func avdManager(_ arguments: [String]) async throws -> String {
        guard let tool = sdk.avdManagerCandidates(listDirectory: listDirectory).first(where: isExecutable) else {
            throw ShellError(command: "avdmanager", exitCode: 1,
                             stderr: "Android command-line tools not found — install them from Android Studio's SDK Manager")
        }
        guard let javaHome = await java.locate() else {
            return try await runner.run(tool, arguments)
        }
        return try await runner.run("/usr/bin/env", ["JAVA_HOME=\(javaHome)", tool] + arguments)
    }
}
