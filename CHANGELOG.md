# Changelog

All notable changes to BootBar are documented here.

## [Unreleased]

### Added

- Android: start without sound, as a global option (device menu then offers Start with Sound) and as a per-launch menu entry
- Android: extra emulator arguments applied to every start, cold boot and wipe
- Per-device tools for simulators and emulators: screenshot, screen recording, dark/light mode, open URL, install app (file, archive or URL), app list with launch/stop/uninstall, location, logs, shell, and platform extras
- Create, rename, clone (iOS) and delete simulators and Android virtual devices
- Release workflow that builds, signs, notarizes and publishes to GitHub (or uploads a build-only artifact)

- BootBar window with a device sidebar, optional live mirror (Android via an in-app H.264 decoder, simulators via screenshots, USB iPhones via macOS capture) and a management column
- Android touch, swipe and key input from the mirror
- Physical Android and iOS devices: listing, install, apps, screenshot, logs and more
- Advanced options when creating an Android emulator (RAM, cores, storage, bezel, GPU, cameras, …) and an Edit Hardware form for existing ones
- `expo-orbit://` and `bootbar://install` links with an install confirmation
- 60 fps simulator mirror from Baguette's H.264 stream, with screenshot polling as the fallback
- Touch, keyboard and buttons for the simulator mirror through Baguette, healing Xcode 27's Device Hub input shadowing first
- Choose the terminal for Shell and Logs (Terminal, iTerm2, Ghostty, kitty, WezTerm, Alacritty, Warp or any other)
- Log panel in the BootBar window: live logcat and simulator logs with search, regular expressions, level and app filters, pause, follow and copy, resizable or full height
- Log panel: foreground-app shortcut, a bounded app picker, per-device filters and configurable columns (reorder, resize, hide, shorter time)
- Log panel: following sticks to the end and stays put when you scroll up, multi-line selection with copy lines or messages, and a Settings → Logs buffer length
- Settings are split into General, Android and Mirror tabs so the window fits on screen
- Delete a device from its row menu, with confirmation
- scrcpy-server engine for the Android mirror (low latency, live touch and drag) with automatic fallback to `screenrecord`
- Install `.aab` and `.apks` on Android through bundletool
- The window shows a Dock icon while it is open
- Button to hide the tools panel; the window shrinks to the device screen
- Keyboard input and Cmd+C/X/A/V for the Android mirror, with automatic clipboard sync for Android (scrcpy) and simulators
- Drag and drop files and folders onto a device: install apps, add photos and videos to simulators, copy anything else to Android's Download folder or a simulator's Files app
- Virtual camera for iOS simulators (webcam, image or looping video), using Baguette's injected `VirtualCamera.dylib`, plus a Relaunch action for simulator apps
- The middle column sizes itself to the device picture (no black bars) and the window follows, so it can be made as small as the device screen

### Changed

- Clicking a device opens its management page
- Settings are grouped into Android, emulator launch and capture sections

## [1.1] - 2026-09-16

### Added

- Menu bar panel listing iOS Simulators and Android Emulators with live state indicators
- Start, stop, cold boot, and erase/wipe actions per device
- Optimistic booting state while emulators register with adb
- Automatic simulator host quit when the last simulator stops
- Support for Xcode 27, which replaces Simulator.app with Device Hub, while keeping Xcode 26 and earlier working
- Android SDK auto-detection with manual override in Settings
- Light and dark mode panel
