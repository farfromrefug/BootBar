import Foundation
import Testing
@testable import BootBarCore

private let simulator = Device(id: "UDID", name: "iPhone", platform: .ios, osVersion: "iOS 27", state: .running)
private let phone = Device(id: "0000-UDID", name: "iPhone", platform: .ios, osVersion: "iOS 27", state: .running, isPhysical: true)
private let emulator = Device(id: "Pixel", name: "Pixel", platform: .android, osVersion: "API 36", state: .running, serial: "emulator-5554")
private let adb = "/sdk/platform-tools/adb -s emulator-5554"

@Test func androidDropsInstallPackagesAndCopyEverythingElse() {
    #expect(FileDrop.action(for: "/x/app.apk", on: emulator) == .install)
    #expect(FileDrop.action(for: "/x/app.AAB", on: emulator) == .install)
    #expect(FileDrop.action(for: "/x/photo.jpg", on: emulator) == .push)
    #expect(FileDrop.action(for: "/x/notes.txt", on: emulator) == .push)
}

@Test func simulatorDropsInstallAppsAndAddMedia() {
    #expect(FileDrop.action(for: "/x/My.app", on: simulator) == .install)
    #expect(FileDrop.action(for: "/x/build.tar.gz", on: simulator) == .install)
    #expect(FileDrop.action(for: "/x/clip.MOV", on: simulator) == .addMedia)
    #expect(FileDrop.action(for: "/x/photo.heic", on: simulator) == .addMedia)
    #expect(FileDrop.action(for: "/x/notes.txt", on: simulator) == .copyToFiles)
    #expect(FileDrop.action(for: "/x/some folder", on: simulator) == .copyToFiles)
}

@Test func physicalIPhoneOnlyTakesApps() {
    #expect(FileDrop.action(for: "/x/app.ipa", on: phone) == .install)
    if case .unsupported = FileDrop.action(for: "/x/photo.jpg", on: phone) {} else { Issue.record("expected unsupported") }
}

private let namer = CaptureNamer(now: { Date(timeIntervalSince1970: 0) }, prepareDirectory: { _ in })

@Test func androidPushCopiesIntoDownloadAndScansMedia() async throws {
    let runner = MockShellRunner()
    let tools = EmulatorTools(runner: runner, sdk: AndroidSDK(root: "/sdk"), avdHome: "/avd", namer: namer, temporaryDirectory: "/tmp")
    let destination = try await tools.pushFile(emulator, path: "/Users/me/My Photo.jpg")
    #expect(destination == "/sdcard/Download/My Photo.jpg")
    #expect(runner.commands == [
        "\(adb) push /Users/me/My Photo.jpg /sdcard/Download/My Photo.jpg",
        "\(adb) shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file:///sdcard/Download/My Photo.jpg'"])
}

@Test func simulatorMediaAndPasteboardCommands() async throws {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl pbpaste UDID"] = .success("copied text")
    let tools = SimulatorTools(runner: runner, namer: namer, temporaryDirectory: NSTemporaryDirectory())
    try await tools.addMedia(simulator, path: "/x/a.jpg")
    #expect(try await tools.pasteboard(simulator) == "copied text")
    #expect(runner.commands == ["/usr/bin/xcrun simctl addmedia UDID /x/a.jpg", "/usr/bin/xcrun simctl pbpaste UDID"])
}

@Test func simulatorPasteboardSyncsThroughPbsync() async throws {
    let runner = MockShellRunner()
    let tools = SimulatorTools(runner: runner, namer: namer, temporaryDirectory: "/tmp")
    try await tools.pushHostPasteboard(simulator)
    try await tools.pullPasteboard(simulator)
    #expect(runner.commands == ["/usr/bin/xcrun simctl pbsync host UDID", "/usr/bin/xcrun simctl pbsync UDID host"])
}

@Test func textAndClipboardMessageLayout() {
    #expect([UInt8](ScrcpyControl.text("héy")) == [1, 0, 0, 0, 4, 0x68, 0xc3, 0xa9, 0x79])
    let clipboard = [UInt8](ScrcpyControl.setClipboard("hi", paste: true, sequence: 7))
    #expect(clipboard == [9, 0, 0, 0, 0, 0, 0, 0, 7, 1, 0, 0, 0, 2, 0x68, 0x69])
    #expect([UInt8](ScrcpyControl.key(code: 29, action: 0, meta: 0x1000)) == [0, 0, 0, 0, 0, 29, 0, 0, 0, 0, 0, 0, 0x10, 0])
}

@Test func deviceMessagesParseAcrossSplits() {
    var parser = ScrcpyDeviceMessageParser()
    let data: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 5] + [0, 0, 0, 0, 7] + Array(" PASTED".utf8) + [0, 0, 0, 0, 2, 0x68, 0x69]
    var messages: [ScrcpyDeviceMessage] = []
    for byte in data { messages += parser.push(Data([byte])) }
    #expect(messages == [.clipboardAck(5), .clipboard(" PASTED"), .clipboard("hi")])
}

@Test func deviceMessageParserSkipsHidOutputAndDropsUnknownFraming() {
    var parser = ScrcpyDeviceMessageParser()
    #expect(parser.push(Data([2, 0, 1, 0, 2, 9, 9, 0, 0, 0, 0, 1, 0x61])) == [.other, .clipboard("a")])
    #expect(parser.push(Data([0x7f, 1, 2, 3])).isEmpty)
    #expect(parser.push(Data([0, 0, 0, 0, 1, 0x62])) == [.clipboard("b")])
}

@MainActor
@Test func droppingMixedFilesReportsTheFirstFailure() async {
    let runner = MockShellRunner()
    let vm = DeviceToolsViewModel(runner: runner, locateSDK: { AndroidSDK(root: "/sdk") })
    await vm.drop(["/x/a.jpg", "/x/b.jpg"], on: emulator)
    #expect(vm.message == DeviceToolsViewModel.Message(text: "Dropped 2 files", isError: false))
    #expect(runner.commands.filter { $0.contains(" push ") }.count == 2)

    await vm.drop(["/x/notes.txt", "/x/a.jpg"], on: phone)
    #expect(vm.message?.isError == true)
    #expect(vm.message?.text.hasPrefix("notes.txt:") == true)
}

private let listAppsWithFiles = """
{
    "com.apple.DocumentsApp" =     {
        ApplicationType = System;
        GroupContainers =         {
            "group.com.apple.FileProvider.LocalStorage" = "file:///Users/me/Devices/U/data/Containers/Shared/AppGroup/ABC/";
        };
    };
    "com.example" =     {
        ApplicationType = User;
    };
}
"""

@Test func findsTheFilesAppStorageFolder() {
    #expect(SimctlParser.fileProviderStorage(listApps: listAppsWithFiles)
            == "/Users/me/Devices/U/data/Containers/Shared/AppGroup/ABC/File Provider Storage")
    #expect(SimctlParser.fileProviderStorage(listApps: "{ \"a\" = { }; }") == nil)
}

@Test func simulatorCopiesIntoTheFilesApp() async throws {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl listapps UDID"] = .success(listAppsWithFiles)
    let tools = SimulatorTools(runner: runner, namer: namer, temporaryDirectory: "/tmp")
    try await tools.copyToFiles(simulator, path: "/x/My Folder")
    let storage = "/Users/me/Devices/U/data/Containers/Shared/AppGroup/ABC/File Provider Storage"
    #expect(runner.commands == ["/usr/bin/xcrun simctl listapps UDID", "/bin/mkdir -p \(storage)", "/bin/cp -R /x/My Folder \(storage)/"])
}

@Test func androidPushOfAFolderGoesToTheDownloadFolder() async throws {
    let directory = NSTemporaryDirectory() + "bb-drop-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let runner = MockShellRunner()
    let tools = EmulatorTools(runner: runner, sdk: AndroidSDK(root: "/sdk"), avdHome: "/avd", namer: namer, temporaryDirectory: "/tmp")
    _ = try await tools.pushFile(emulator, path: directory)
    #expect(runner.commands.first == "\(adb) push \(directory) /sdcard/Download/")
}
