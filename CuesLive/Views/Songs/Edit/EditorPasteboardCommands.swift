#if os(macOS)
import AppKit
import SwiftUI

/// Cut, Copy, Paste, Delete and Select All act on the song editor while it is open, wherever focus
/// sits in the window. A focused text field keeps the standard text behaviour.
struct EditorPasteboardCommands: Commands {
    @FocusedValue(\.clipEditorActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                perform(#selector(NSText.cut(_:))) { $0.cut() }
            }
            .keyboardShortcut("x", modifiers: .command)

            Button("Copy") {
                perform(#selector(NSText.copy(_:))) { $0.copy() }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Paste") {
                perform(#selector(NSText.paste(_:))) { $0.paste() }
            }
            .keyboardShortcut("v", modifiers: .command)

            Button("Delete") {
                perform(#selector(NSText.delete(_:))) { $0.delete() }
            }

            Button("Select All") {
                perform(#selector(NSText.selectAll(_:))) { $0.selectAll() }
            }
            .keyboardShortcut("a", modifiers: .command)
        }
    }

    private func perform(_ textAction: Selector, editorAction: (ClipEditorActions) -> Void) {
        if let actions, !(NSApp.keyWindow?.firstResponder is NSText) {
            editorAction(actions)
        } else {
            NSApp.sendAction(textAction, to: nil, from: nil)
        }
    }
}
#endif
