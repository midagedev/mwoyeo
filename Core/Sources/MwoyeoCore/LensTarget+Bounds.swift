import CoreGraphics
import Foundation

/// What a one-click target may cover (round picktarget117, A2: in the skinland117 take a picker hop stretched the spotlight below the PDF window over
/// the Dock, to y 968 of 982). The picker reads the whole display, so the Dock's labels and icons, the menu bar and every other window's text are
/// blocks of the same map, and a block of the Dock whose x lies in a page's column is a member of that column. The target is clamped to the content
/// of the window under the pointer (`content(of:on:)`); but with the pointer over no window (the Dock, the menu bar, the desktop) the display was
/// the clamp, and the column's members below the page's window carried the target over them.
extension LensTarget {
    /// What a target may cover with the pointer over `window` (its frame from the window list, y down; nil over none) on `display`: the window's
    /// content below its title bar. Nil where there is no target to be had: the list has windows (`windowsKnown`) and the pointer is over none of them,
    /// so the column under it belongs to nothing a lens could follow. With no window list at all (no permission, a check), the display, as before.
    public static func targetBounds(over window: CGRect?, windowsKnown: Bool, on display: CGRect) -> CGRect? {
        if window == nil, windowsKnown { return nil }
        return content(of: window, on: display)
    }
}
