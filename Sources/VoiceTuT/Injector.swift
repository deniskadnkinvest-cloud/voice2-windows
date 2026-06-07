import Cocoa

// Primary injection method: clipboard + Cmd+V.
// Works in every app without Accessibility permission.
// After paste the transcribed text stays in clipboard so the user can Cmd+V manually.

enum Injector {
    static func paste(_ text: String) {
        // Write text to clipboard immediately.
        writeClipboard(text)

        // Re-write right before sending Cmd+V to survive any race where the
        // target app or system briefly overwrites the pasteboard during activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            writeClipboard(text)

            let src = CGEventSource(stateID: .hidSystemState)
            func key(_ code: CGKeyCode, down: Bool) {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
            key(0x09, down: true)   // Cmd+V down
            key(0x09, down: false)  // Cmd+V up

            print("[Injector] Pasted \(text.count) chars")
        }
    }

    private static func writeClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
