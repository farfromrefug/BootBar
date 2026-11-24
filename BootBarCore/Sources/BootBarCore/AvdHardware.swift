import Foundation

/// Hardware knobs of an Android virtual device, stored in its `config.ini`. `nil` leaves the default alone.
public struct AvdHardwareOptions: Sendable, Equatable {
    public enum GPUMode: String, Sendable, CaseIterable, Equatable {
        case auto, host, swiftshaderIndirect = "swiftshader_indirect", angleIndirect = "angle_indirect", guest

        public var title: String {
            switch self {
            case .auto: "Automatic"
            case .host: "Hardware"
            case .swiftshaderIndirect: "Software (SwiftShader)"
            case .angleIndirect: "ANGLE"
            case .guest: "Guest"
            }
        }
    }

    public enum Camera: String, Sendable, CaseIterable, Equatable {
        case none, emulated, webcam0, virtualscene

        public var title: String {
            switch self {
            case .none: "None"
            case .emulated: "Emulated"
            case .webcam0: "Webcam"
            case .virtualscene: "Virtual scene"
            }
        }
    }

    public enum Orientation: String, Sendable, CaseIterable, Equatable {
        case portrait, landscape
    }

    public var ramMB: Int?
    public var cpuCores: Int?
    public var internalStorageMB: Int?
    /// Only honoured when creating: `avdmanager --sdcard`.
    public var sdCardMB: Int?
    public var vmHeapMB: Int?
    public var lcdDensity: Int?
    public var gpuMode: GPUMode?
    public var showDeviceFrame: Bool?
    public var hardwareKeyboard: Bool?
    public var coldBootOnly: Bool?
    public var frontCamera: Camera?
    public var backCamera: Camera?
    public var initialOrientation: Orientation?

    public init(ramMB: Int? = nil, cpuCores: Int? = nil, internalStorageMB: Int? = nil, sdCardMB: Int? = nil,
                vmHeapMB: Int? = nil, lcdDensity: Int? = nil, gpuMode: GPUMode? = nil, showDeviceFrame: Bool? = nil,
                hardwareKeyboard: Bool? = nil, coldBootOnly: Bool? = nil, frontCamera: Camera? = nil,
                backCamera: Camera? = nil, initialOrientation: Orientation? = nil) {
        self.ramMB = ramMB
        self.cpuCores = cpuCores
        self.internalStorageMB = internalStorageMB
        self.sdCardMB = sdCardMB
        self.vmHeapMB = vmHeapMB
        self.lcdDensity = lcdDensity
        self.gpuMode = gpuMode
        self.showDeviceFrame = showDeviceFrame
        self.hardwareKeyboard = hardwareKeyboard
        self.coldBootOnly = coldBootOnly
        self.frontCamera = frontCamera
        self.backCamera = backCamera
        self.initialOrientation = initialOrientation
    }

    public var isEmpty: Bool { self == AvdHardwareOptions() }

    /// `config.ini` lines for the options that are set.
    public var configEntries: [(key: String, value: String)] {
        var entries: [(String, String)] = []
        if let ramMB { entries.append(("hw.ramSize", "\(ramMB)")) }
        if let cpuCores { entries.append(("hw.cpu.ncore", "\(cpuCores)")) }
        if let internalStorageMB { entries.append(("disk.dataPartition.size", "\(internalStorageMB)M")) }
        if let vmHeapMB { entries.append(("vm.heapSize", "\(vmHeapMB)")) }
        if let lcdDensity { entries.append(("hw.lcd.density", "\(lcdDensity)")) }
        if let gpuMode {
            entries.append(("hw.gpu.enabled", "yes"))
            entries.append(("hw.gpu.mode", gpuMode.rawValue))
        }
        if let showDeviceFrame { entries.append(("showDeviceFrame", Self.yesNo(showDeviceFrame))) }
        if let hardwareKeyboard { entries.append(("hw.keyboard", Self.yesNo(hardwareKeyboard))) }
        if let coldBootOnly {
            entries.append(("fastboot.forceColdBoot", Self.yesNo(coldBootOnly)))
            entries.append(("fastboot.forceFastBoot", Self.yesNo(!coldBootOnly)))
        }
        if let frontCamera { entries.append(("hw.camera.front", frontCamera.rawValue)) }
        if let backCamera { entries.append(("hw.camera.back", backCamera.rawValue)) }
        if let initialOrientation { entries.append(("hw.initialOrientation", initialOrientation.rawValue)) }
        return entries
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}

public enum AvdConfigEditor {
    /// Replaces the value of existing keys in place and appends the missing ones.
    public static func merge(_ ini: String, entries: [(key: String, value: String)]) -> String {
        var lines = ini.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for entry in entries {
            if let index = lines.firstIndex(where: { key(of: $0) == entry.key }) {
                lines[index] = "\(entry.key)=\(entry.value)"
            } else {
                lines.append("\(entry.key)=\(entry.value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads the supported options back from a `config.ini`.
    public static func parse(_ ini: String) -> AvdHardwareOptions {
        var values: [String: String] = [:]
        for line in ini.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        func bool(_ key: String) -> Bool? { values[key].map { $0 == "yes" || $0 == "true" } }
        return AvdHardwareOptions(
            ramMB: megabytes(values["hw.ramSize"], defaultUnit: "M"),
            cpuCores: values["hw.cpu.ncore"].flatMap(Int.init),
            internalStorageMB: megabytes(values["disk.dataPartition.size"], defaultUnit: "B"),
            vmHeapMB: megabytes(values["vm.heapSize"], defaultUnit: "M"),
            lcdDensity: values["hw.lcd.density"].flatMap(Int.init),
            gpuMode: values["hw.gpu.mode"].flatMap(AvdHardwareOptions.GPUMode.init(rawValue:)),
            showDeviceFrame: bool("showDeviceFrame"),
            hardwareKeyboard: bool("hw.keyboard"),
            coldBootOnly: bool("fastboot.forceColdBoot"),
            frontCamera: values["hw.camera.front"].flatMap(AvdHardwareOptions.Camera.init(rawValue:)),
            backCamera: values["hw.camera.back"].flatMap(AvdHardwareOptions.Camera.init(rawValue:)),
            initialOrientation: values["hw.initialOrientation"].flatMap(AvdHardwareOptions.Orientation.init(rawValue:)))
    }

    private static func key(of line: String) -> String? {
        line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "2048", "2048MB", "10G", "512M" or a raw byte count to megabytes.
    static func megabytes(_ value: String?, defaultUnit: Character) -> Int? {
        guard var text = value?.uppercased().replacingOccurrences(of: " ", with: ""), !text.isEmpty else { return nil }
        var unit = defaultUnit
        if text.hasSuffix("B"), text.count > 1, text.dropLast().last?.isLetter == true { text.removeLast() }
        if let last = text.last, last.isLetter {
            unit = last
            text.removeLast()
        }
        guard let number = Double(text) else { return nil }
        switch unit {
        case "G": return Int(number * 1024)
        case "K": return Int(number / 1024)
        case "B": return Int(number / 1_048_576)
        default: return Int(number)
        }
    }
}
