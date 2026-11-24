import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePicker {
    static func chooseFile(extensions: [String], completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = extensions.contains("app")
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        present(panel, completion: completion)
    }

    static func chooseDirectory(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        present(panel, completion: completion)
    }

    private static func present(_ panel: NSOpenPanel, completion: @escaping (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url.path)
        }
    }
}
