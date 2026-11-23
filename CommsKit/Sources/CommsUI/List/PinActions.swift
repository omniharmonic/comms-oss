import CommsClient
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// What the list's Pin / Unpin actions do (sprint Task 8). Nil on a list = no pin actions
/// (the server does not offer pins, snapshots, the design gallery).
struct PinActions {
    var isPinned: (String) -> Bool
    var toggle: (String) -> Void
    /// Move a pin to a position in the grid (drag to reorder).
    var move: (String, Int) -> Void

    static func label(pinned: Bool) -> String { pinned ? "Unpin" : "Pin" }
    static func symbol(pinned: Bool) -> String { pinned ? "pin.slash" : "pin" }
}

extension View {
    /// Messages' Pin / Unpin: the context menu (right-click on the Mac, long-press on the phone),
    /// a VoiceOver action, and on the phone the leading swipe (yellow Pin button; a full swipe pins).
    @ViewBuilder
    func pinActions(_ actions: PinActions?, threadID: String) -> some View {
        if let actions {
            let pinned = actions.isPinned(threadID)
            let title = PinActions.label(pinned: pinned)
            self
                .contextMenu {
                    Button(title, systemImage: PinActions.symbol(pinned: pinned)) { actions.toggle(threadID) }
                        .accessibilityIdentifier("pin-menu-\(threadID)")
                }
                .accessibilityAction(named: Text(title)) { actions.toggle(threadID) }
                #if os(iOS)
                .modifier(RowSwipe(id: "pin-\(threadID)", leading: [SwipeItem(title: title, systemImage: pinned ? "pin.slash.fill" : "pin.fill",
                                                                            color: Color(uiColor: .systemYellow), identifier: "swipe-pin-\(threadID)") { actions.toggle(threadID) }],
                                   trailing: []))
                #endif
        } else {
            self
        }
    }
}
