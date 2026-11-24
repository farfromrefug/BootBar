<p align="center">
  <h1 align="center">BootBar</h1>
  <p align="center">Boot, stop, and manage iOS Simulators and Android Emulators — from your macOS menu bar.</p>
</p>

<p align="center">
  <a href="https://github.com/dipendra-sharma/BootBar/actions/workflows/ci.yml"><img src="https://github.com/dipendra-sharma/BootBar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue.svg" alt="Platform macOS 14+">
  <img src="https://img.shields.io/badge/license-MIT-brightgreen.svg" alt="License MIT">
  <a href="https://github.com/dipendra-sharma/BootBar/releases/latest"><img src="https://img.shields.io/github/downloads/dipendra-sharma/BootBar/total.svg" alt="Downloads"></a>
</p>

## About

BootBar is a native SwiftUI menu bar app that puts your entire mobile device toolchain one click away. One panel for **both** Apple and Google toolchains — list, start, stop, cold-boot, and erase/wipe iOS Simulators and Android Emulators without touching Xcode, Android Studio, or a terminal.

No Electron, no daemons, no telemetry. A single lightweight panel driving `simctl`, `emulator`, and `adb` underneath.

## Features

- 🍎 **iOS Simulators** — list available devices with runtime version, boot (opens Simulator.app, or Device Hub on Xcode 27+), shutdown, cold boot, erase content and settings
- 🤖 **Android Emulators** — list AVDs with API level, start, stop, cold boot (`-no-snapshot-load`), wipe data (`-wipe-data`)
- 🔇 **Launch options** — start Android emulators without sound (globally, or for a single launch), and pass any extra `emulator` arguments to every start
- 🛠️ **Per-device tools** — screenshots, screen recording, dark/light mode, open URLs, install apps (`.app`, `.apk`, or a `.tar.gz` / URL from EAS and Expo), browse/launch/uninstall apps, set location, logs and shell in Terminal
- ➕ **Virtual device management** — create, rename, clone (iOS) and delete simulators and AVDs, without Xcode or Android Studio
- 🪟 **BootBar window** — a device-hub style window: devices on the left, an optional live mirror in the middle, management on the right
- 📱 **Physical devices** — Android phones (adb) and iPhones/iPads (devicectl) next to your simulators: install, apps, screenshots, mirror
- 🔗 **Install links** — `expo-orbit://` links download an EAS/Expo build and install it on the device you pick
- 🟢 **Live state tracking** — running / booting / stopped indicators refresh automatically while the panel is open
- 🧹 **Tidy by design** — quits the simulator host app automatically when the last simulator stops, so no orphan dock icons
- 🔍 **Android SDK auto-detection** — finds your SDK via `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, or the default install path, with a manual override in Settings
- 🪶 **Native and lightweight** — pure SwiftUI `MenuBarExtra`, zero third-party dependencies, no dock icon

## Preview

| Light | Dark |
| :---: | :---: |
| <img src="docs/assets/panel-light.png" width="340" alt="BootBar panel light mode"> | <img src="docs/assets/panel-dark.png" width="340" alt="BootBar panel dark mode"> |

## Installation

### Build from source

```bash
git clone https://github.com/dipendra-sharma/BootBar.git
cd BootBar
xcodebuild -project BootBar.xcodeproj -scheme BootBar -derivedDataPath build build
open "build/Build/Products/Debug/BootBar.app"
```

Or open `BootBar.xcodeproj` in Xcode and press Run.

Signed and notarized builds are published on the [Releases](https://github.com/farfromrefug/BootBar/releases) page.

## Requirements

- macOS 14 or later
- Xcode (for `xcrun simctl` — iOS section)
- Android SDK with `emulator` and `platform-tools` (Android section)

> [!IMPORTANT]
> Each platform section degrades independently. No Xcode? The iOS section shows a hint while Android keeps working — and vice versa. Neither toolchain is required for the app to launch.

## Usage

1. Click the phone icon in the menu bar
2. Press ▶ to boot a device, ■ to stop it
3. The ⋯ menu holds **Cold Boot** and **Erase / Wipe Data**
4. The panel auto-refreshes every 5 seconds while open
5. Set a custom Android SDK path via **Settings** in the footer

### Device tools

Click a device to open its page, or open its **⋯** menu for the quick actions (start without/with sound, cold boot, wipe, screenshot, recording, appearance) or **Manage…** for the rest. Nothing is queried when a menu opens: the installed-app list is fetched only when you expand **Apps**, and the new-device form loads its options only when it opens.

| Tool | iOS | Android |
| --- | --- | --- |
| Screenshot / record | `simctl io` | `screencap` / emulator console `screenrecord` |
| Dark / light | `simctl ui appearance` | `cmd uimode night` |
| Open URL | `simctl openurl` | `am start -a VIEW` |
| Install | `simctl install` | `adb install -r`; `.aab` / `.apks` through `bundletool` (`brew install bundletool`) |
| Apps | `simctl listapps`, launch, terminate, uninstall, show data folder | `pm list packages`, launch, force-stop, uninstall, clear data |
| Location | `simctl location` | `emu geo fix` |
| Extras | clean 9:41 status bar | rotate, animations, show taps, reboot, shell |
| Logs | `log stream` in a terminal | `logcat` in a terminal |

Shell and Logs open in the terminal chosen in Settings → Terminal: Terminal, iTerm2, Ghostty, kitty, WezTerm, Alacritty, Warp, or any other app that opens a `.command` file.

Install accepts a local file or an `http(s)` URL; archives (`.tar.gz`, `.zip`) are unpacked and the `.app` inside is installed. Screenshots and recordings go to the folder set in Settings (default: Desktop).

### BootBar window

The window icon in the panel header (or **Open in the BootBar window** on a device page) opens the hub. Select a device in the sidebar; the middle column shows its live screen and the right column holds the same tools as the panel. The **Mirror** toolbar button hides the middle column; the **Tools** button hides the right one and shrinks the window down to the device screen. With the tools panel shown it can be as wide as you like.

| Device | Mirror | Input |
| --- | --- | --- |
| Android emulator / phone | scrcpy's server when scrcpy is installed (low latency, live touch and drag); otherwise the H.264 stream of `screenrecord`. The pane shows which engine is active | click, drag and swipe, Back / Home / Overview / volume / power buttons |
| iOS Simulator | Baguette's H.264 stream at up to 60 fps (screenshot polling when Baguette is not installed) | click, drag, swipe, keyboard, Home / App Switcher / Lock buttons, through Baguette (`brew install baguette`) |
| iPhone / iPad | macOS capture of the USB-connected device (needs camera permission and a cable) | none |

`brew install scrcpy` switches the window to scrcpy's server automatically (BootBar talks to it directly, no scrcpy window opens). **Tools → scrcpy** still opens scrcpy's own window. While the window is open BootBar also shows in the Dock.

### Keyboard, clipboard and drag & drop

- **Keyboard** (Android): click the picture and type. Text, Return, Delete, Tab, arrows and Esc (Back) go to the device; Cmd+C / X / A / V copy, cut, select all and paste. With the adb fallback engine only typing and special keys work.
- **Clipboard**: while a mirror is open the Mac and the device clipboards are kept in sync (scrcpy engine for Android, `simctl pbsync` for simulators). Settings → Mirror turns it off.
- **Drag & drop** files or folders on the window. Android: `.apk` / `.aab` / `.apks` install, everything else (folders included) is copied to `Download`. Simulators: `.app` / `.tar.gz` / `.zip` install, photos and videos go to the Photos library, everything else (folders included) lands in Files › On My iPhone. iPhones and iPads: `.ipa` / `.app` install; Apple gives no way to copy arbitrary files to a real device.
- Simulators: touch, swipe, typing (non-ASCII is pasted) and Cmd+C / V / A / X work through [Baguette](https://github.com/tddworks/baguette)'s `baguette input`, which uses the private SimulatorKit input surface Apple does not expose. Without Baguette the picture is view-only. On Xcode 27 the first connection runs `baguette heal` (restarts SpringBoard) so Device Hub does not swallow the touches. **Open Simulator** jumps to the real host app.

### Virtual camera for iOS simulators

A simulator has no camera. **Camera** (simulator page) feeds a Mac webcam, a still image or a looping video to the camera of any app launched afterwards, so scanners, photo capture and viewfinders can be tested.

1. `brew install baguette` once. BootBar uses [Baguette](https://github.com/tddworks/baguette)'s `VirtualCamera.dylib` (it fakes the camera inside the app); BootBar supplies the frames and arms it in the simulator.
2. Pick a source and press **Start Camera**.
3. **Relaunch the app** (Apps → ⋯ → **Relaunch**): the library is only loaded when an app starts.
4. **Stop Camera** removes it again, and so does quitting BootBar. Only one camera can run at a time on the Mac, and BootBar and Baguette cannot both run one.

Limits (they come from the library): no audio, and no barcode metadata objects are synthesised, so apps that scan through `AVCaptureMetadataOutput` see the picture but detect nothing.

### Physical devices

Shown in their own section (Settings → Physical devices turns it off). Android phones need USB debugging enabled and authorised; iPhones and iPads must be paired in Xcode. Real devices have no start/stop, no emulator console and no simulator switches, so only the tools that make sense are offered: install, apps, screenshot, logs, shell, reboot (Android), recording (iOS).

### Install links

`expo-orbit:///download?url=https://…` and `bootbar://install?url=https://…` open the window with a confirmation sheet listing the running devices that can take the build (`.apk`, `.apks` or `.aab` for Android, `.tar.gz` for simulators, `.ipa` for iPhones). Nothing is downloaded until you press **Download & Install**. Expo Orbit registers the same `expo-orbit` scheme; choose who gets the links in Settings → Install links.

### Android hardware options

When creating an emulator, **Advanced options** sets memory, CPU cores, internal storage, SD card, VM heap, screen density, graphics mode, device frame (bezel), hardware keyboard, cold-boot behaviour, cameras and orientation. They are written to the AVD's `config.ini`. The same form is under **Manage → Device → Edit Hardware…** for stopped emulators.

### Launch options (Android)

In **Settings → Emulator launch**:

- **Start without sound** adds `-no-audio` to every start, cold boot and wipe. The device menu then offers **Start with Sound** for a single launch; with the option off it offers **Start without Sound**.
- **Extra arguments** are appended to every launch, e.g. `-gpu host -no-boot-anim`.

### Virtual devices

The **+** button in each section creates a device. iOS uses the installed runtimes and device types; Android uses the system images already installed in your SDK together with `avdmanager` (found under `cmdline-tools`, run with Android Studio's bundled Java when `JAVA_HOME` is not set). Rename, clone and delete live under **Manage… → Device** and require the device to be stopped.

| Action | iOS | Android |
| --- | --- | --- |
| Start | `simctl boot` + opens the simulator host app | `emulator -avd` |
| Stop | `simctl shutdown` | `adb emu kill` |
| Cold Boot | shutdown → boot | restart with `-no-snapshot-load` |
| Erase / Wipe | `simctl erase` | restart with `-wipe-data` |

## Architecture

All device logic lives in `BootBarCore`, a local Swift package with full unit test coverage (parsers and services tested against real CLI output fixtures). The app target contains only SwiftUI views.

```bash
cd BootBarCore
swift test
```

## FAQ

**No iOS simulators listed?** Make sure Xcode is installed and `xcrun simctl list devices` works in a terminal.

**No Android emulators listed?** BootBar looks for the SDK at `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`. Set the path manually in Settings if yours lives elsewhere.

**A device stays "Booting…" for a while?** Android emulators take 30-60 s to register with `adb` after launch. The dot turns green as soon as the device reports in.

**Does it phone home?** No. BootBar makes no network requests of its own; the only download is the one you trigger with *Install App → URL*.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Please use the issue templates for bugs and feature requests.

## Acknowledgements

[MiniSim](https://github.com/okwasniewski/MiniSim) and [Control Room](https://github.com/twostraws/ControlRoom) explored this space first and remain excellent tools.

## License

[MIT](LICENSE) © Dipendra Sharma
