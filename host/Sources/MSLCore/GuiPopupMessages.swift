import Foundation

/// Guest→host `popup_new` {win, parent, x, y, w, h, scale}: an xdg_popup as a
/// child panel. `x, y` are logical points of the popup's geometry origin
/// relative to the parent's, top-left, y-down; `w, h` are the first buffer's
/// window-geometry pixels and `scale` its render scale, exactly as in win_new.
public struct GuiPopupNew: Codable, Sendable, Equatable {
    public let win: UInt32
    public let parent: UInt32
    public let posX: Int32
    public let posY: Int32
    public let width: UInt32
    public let height: UInt32
    public let scale: Double

    enum CodingKeys: String, CodingKey {
        case win, parent, scale
        case posX = "x"
        case posY = "y"
        case width = "w"
        case height = "h"
    }

    public init(
        win: UInt32, parent: UInt32, posX: Int32, posY: Int32, width: UInt32, height: UInt32,
        scale: Double
    ) {
        self.win = win
        self.parent = parent
        self.posX = posX
        self.posY = posY
        self.width = width
        self.height = height
        self.scale = scale
    }
}

/// Guest→host `popup_moved` {win, x, y}: the popup's parent-relative geometry
/// origin changed (xdg_popup.reposition). Units as in `popup_new`.
public struct GuiPopupMoved: Codable, Sendable, Equatable {
    public let win: UInt32
    public let posX: Int32
    public let posY: Int32

    enum CodingKeys: String, CodingKey {
        case win
        case posX = "x"
        case posY = "y"
    }

    public init(win: UInt32, posX: Int32, posY: Int32) {
        self.win = win
        self.posX = posX
        self.posY = posY
    }
}

/// Host→guest `popup_dismiss` {win}: the host observed an interaction that must
/// close this popup and every popup above it in the grab stack.
public struct GuiPopupDismiss: Codable, Sendable, Equatable {
    public let win: UInt32
    public init(win: UInt32) { self.win = win }
}
