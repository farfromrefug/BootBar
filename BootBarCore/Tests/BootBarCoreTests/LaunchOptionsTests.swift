import Testing
@testable import BootBarCore

@Test func splitsOnWhitespace() {
    #expect(ArgumentSplitter.split("-gpu host  -no-boot-anim") == ["-gpu", "host", "-no-boot-anim"])
}

@Test func splitHonoursQuotesAndEscapes() {
    #expect(ArgumentSplitter.split(#"-prop "a b" 'c d' e\ f"#) == ["-prop", "a b", "c d", "e f"])
    #expect(ArgumentSplitter.split(#"-writable-system ''"#) == ["-writable-system", ""])
}

@Test func splitOfBlankIsEmpty() {
    #expect(ArgumentSplitter.split("   ").isEmpty)
}

@Test func defaultOptionsAddNothing() {
    #expect(AndroidLaunchOptions().arguments().isEmpty)
}

@Test func muteAddsNoAudioBeforeExtras() {
    let options = AndroidLaunchOptions(muteAudio: true, extraArguments: "-gpu host")
    #expect(options.arguments() == ["-no-audio", "-gpu", "host"])
}

@Test func overrideBeatsGlobalMute() {
    let muted = AndroidLaunchOptions(muteAudio: true, extraArguments: "-gpu host")
    #expect(muted.arguments(muted: false) == ["-gpu", "host"])
    #expect(AndroidLaunchOptions().arguments(muted: true) == ["-no-audio"])
}

@Test func unmutedStripsAudioFlagTypedInExtras() {
    let options = AndroidLaunchOptions(muteAudio: false, extraArguments: "-no-audio -gpu host")
    #expect(options.arguments() == ["-gpu", "host"])
}

@Test func mutedDoesNotDuplicateAudioFlag() {
    let options = AndroidLaunchOptions(muteAudio: true, extraArguments: "-no-audio")
    #expect(options.arguments() == ["-no-audio"])
}

@Test func remoteShellQuotesSingleQuotes() {
    #expect(RemoteShell.quote("a'b&c") == "'a'\\''b&c'")
}
