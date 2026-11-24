public enum Platform: String, Sendable, CaseIterable {
    case ios
    case android
}

public enum DeviceState: Sendable, Equatable {
    case stopped
    case booting
    case running
    /// Physical device that is attached but not usable yet (unauthorized, offline, unpaired).
    case unavailable
}

public enum DeviceAction: Sendable {
    case start
    /// Android only: starts with the opposite of the global "mute audio" option. Plain start on iOS.
    case startWithAlternateAudio
    case stop
    case coldBoot
    case erase
}

public struct Device: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let platform: Platform
    public let osVersion: String
    public let state: DeviceState
    public let serial: String?
    public let isPhysical: Bool
    /// Why a physical device is `.unavailable`, ready to show to the user.
    public let statusNote: String?

    public init(id: String, name: String, platform: Platform, osVersion: String, state: DeviceState,
                serial: String? = nil, isPhysical: Bool = false, statusNote: String? = nil) {
        self.id = id
        self.name = name
        self.platform = platform
        self.osVersion = osVersion
        self.state = state
        self.serial = serial
        self.isPhysical = isPhysical
        self.statusNote = statusNote
    }

    public func withState(_ newState: DeviceState) -> Device {
        Device(id: id, name: name, platform: platform, osVersion: osVersion, state: newState, serial: serial,
               isPhysical: isPhysical, statusNote: statusNote)
    }
}
