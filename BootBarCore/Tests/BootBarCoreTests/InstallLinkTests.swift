import Foundation
import Testing
@testable import BootBarCore

private func parse(_ text: String) -> InstallRequest? { URL(string: text).flatMap(InstallLink.parse) }

@Test func parsesOrbitDownloadLinks() {
    let request = parse("expo-orbit:///download?url=https%3A%2F%2Fexpo.dev%2Fartifacts%2Feas%2Fabc.tar.gz")
    #expect(request?.url.absoluteString == "https://expo.dev/artifacts/eas/abc.tar.gz")
    #expect(request?.platform == .ios)
}

@Test func infersAndroidFromApk() {
    #expect(parse("expo-orbit://download?url=https://expo.dev/a/b.apk")?.platform == .android)
}

@Test func explicitPlatformWins() {
    #expect(parse("bootbar://install?url=https://x.dev/build.zip&platform=android")?.platform == .android)
    #expect(parse("bootbar://install?url=https://x.dev/build.zip")?.platform == nil)
}

@Test func rejectsOtherSchemesAndNonWebTargets() {
    #expect(parse("https://example.com/?url=https://x.dev/a.apk") == nil)
    #expect(parse("expo-orbit:///download") == nil)
    #expect(parse("expo-orbit:///download?url=file:///etc/passwd") == nil)
    #expect(parse("expo-orbit:///download?url=javascript:alert(1)") == nil)
}

@Test func infersAndroidFromBundles() {
    #expect(parse("expo-orbit:///download?url=https://x.dev/app.aab")?.platform == .android)
    #expect(parse("expo-orbit:///download?url=https://x.dev/app.apks")?.platform == .android)
}
