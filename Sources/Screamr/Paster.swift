import AppKit

/// Inserts text into the focused app by pasting, then puts the user's clipboard back.
enum Paster {
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { acc, type in acc[type] = item.data(forType: type) }
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)
        // nspasteboard.org convention: clipboard managers skip items carrying this type.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let ourChange = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }

        // ponytail: fixed delay before restoring; slow apps (Electron, remote desktops) may paste the old clipboard if they read it later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pb.changeCount == ourChange else { return } // user copied something meanwhile
            pb.clearContents()
            pb.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }
    }
}
