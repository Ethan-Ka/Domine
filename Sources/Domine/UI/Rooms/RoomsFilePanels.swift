import AppKit
import UniformTypeIdentifiers

/// Save and open panels for `.domine-rooms` files.
@MainActor
enum RoomsFilePanels {
    private static var type: UTType {
        UTType(filenameExtension: RoomsFile.fileExtension) ?? .json
    }

    static func export(_ rooms: [Room]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "Rooms.\(RoomsFile.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RoomsFile.encode(rooms).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Returns the rooms in the chosen file, or nil if cancelled or invalid.
    static func importRooms() -> [Room]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try RoomsFile.decode(Data(contentsOf: url))
        } catch {
            let alert = NSAlert()
            alert.messageText = "This file isn't a Domine rooms file."
            alert.runModal()
            return nil
        }
    }
}
