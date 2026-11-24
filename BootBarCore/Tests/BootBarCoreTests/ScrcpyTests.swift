import Foundation
import Testing
@testable import BootBarCore

private func be32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * (3 - $0))) & 0xff) } }

private func handshake(name: String = "sdk_gphone64_arm64", codec: String = "h264", width: Int = 576, height: Int = 1280) -> Data {
    var nameBytes = Array(name.utf8)
    nameBytes += [UInt8](repeating: 0, count: 64 - nameBytes.count)
    return Data(nameBytes + Array(codec.utf8) + [0x80, 0, 0, 0] + be32(width) + be32(height))
}

private func packet(_ payload: [UInt8], flags: UInt8 = 0) -> Data {
    Data([flags, 0, 0, 0, 0, 0, 0, 0] + be32(payload.count) + payload)
}

@Test func streamParserReadsHandshakeThenPackets() throws {
    var parser = ScrcpyStreamParser()
    let first: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2]
    let second: [UInt8] = [0, 0, 0, 1, 0x65, 9, 9, 9]
    let packets = try parser.push(handshake() + packet(first, flags: 0x40) + packet(second))
    #expect(packets == [Data(first), Data(second)])
    #expect(parser.deviceName == "sdk_gphone64_arm64")
    #expect(parser.width == 576)
    #expect(parser.height == 1280)
}

@Test func streamParserHandlesArbitrarySplits() throws {
    var parser = ScrcpyStreamParser()
    let payload: [UInt8] = [0, 0, 0, 1, 0x41, 5, 6, 7, 8]
    var packets: [Data] = []
    for byte in handshake() + packet(payload) + packet(payload) { packets += try parser.push(Data([byte])) }
    #expect(packets == [Data(payload), Data(payload)])
}

@Test func streamParserRejectsOtherCodecsAndAbsurdPackets() {
    var other = ScrcpyStreamParser()
    #expect(throws: ScrcpyStreamParser.ParseError.unsupportedCodec("h265")) {
        _ = try other.push(handshake(codec: "h265"))
    }
    var huge = ScrcpyStreamParser()
    #expect(throws: ScrcpyStreamParser.ParseError.oversizedPacket(0x7fff_ffff)) {
        _ = try huge.push(handshake() + Data([0, 0, 0, 0, 0, 0, 0, 0] + be32(0x7fff_ffff)))
    }
}

@Test func touchMessageLayout() {
    let message = [UInt8](ScrcpyControl.touch(.down, x: 288, y: 640, width: 576, height: 1280))
    #expect(message.count == 32)
    #expect(Array(message[0..<2]) == [2, 0])
    #expect(Array(message[2..<10]) == [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe])
    #expect(Array(message[10..<14]) == be32(288))
    #expect(Array(message[14..<18]) == be32(640))
    #expect(Array(message[18..<22]) == [0x02, 0x40, 0x05, 0x00])
    #expect(Array(message[22..<24]) == [0xff, 0xff])
    #expect([UInt8](ScrcpyControl.touch(.up, x: 1, y: 2, width: 3, height: 4))[22..<24] == [0, 0])
}

@Test func keyMessageLayout() {
    #expect([UInt8](ScrcpyControl.key(code: 3, action: 1)) == [0, 1] + be32(3) + be32(0) + be32(0))
}

@Test func parsesScrcpyVersion() {
    #expect(ScrcpyInstall.parseVersion("scrcpy 5.0.1 <https://github.com/Genymobile/scrcpy>\n\n  dependencies") == "5.0.1")
    #expect(ScrcpyInstall.parseVersion("nothing") == nil)
}

@Test func locatesHomebrewInstall() async {
    let runner = MockShellRunner()
    runner.responses["/opt/homebrew/bin/scrcpy --version"] = .success("scrcpy 3.3.3 <https://x>\n")
    let present: Set<String> = ["/opt/homebrew/bin/scrcpy", "/opt/homebrew/share/scrcpy/scrcpy-server"]
    let install = await ScrcpyInstall.locate(runner: runner, exists: { present.contains($0) }, environment: [:])
    #expect(install == ScrcpyInstall(serverPath: "/opt/homebrew/share/scrcpy/scrcpy-server", version: "3.3.3"))
    #expect(await ScrcpyInstall.locate(runner: runner, exists: { _ in false }, environment: [:]) == nil)
}
