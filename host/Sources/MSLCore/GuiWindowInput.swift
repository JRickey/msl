import AppKit
import Foundation

// Input translation for GuiWindow, called by the content view on the main
// thread: NSEvents become protocol pointer/key messages stamped for the ledger.

extension GuiWindow {
    /// Window-local logical pointer state for one event (top-left origin).
    struct PointerSample {
        let kind: String
        let posX: Double
        let posY: Double
        var button: UInt32 = 0
        var state: UInt32 = 0
        var dx: Double = 0
        var dy: Double = 0
    }

    func pointerMotion(posX: Double, posY: Double) {
        sendPointer(PointerSample(kind: "motion", posX: posX, posY: posY), note: true)
    }

    func pointerButton(button: UInt32, down: Bool, posX: Double, posY: Double) {
        sendPointer(
            PointerSample(
                kind: "button", posX: posX, posY: posY, button: button, state: down ? 1 : 0),
            note: true)
    }

    func pointerAxis(dx: Double, dy: Double, posX: Double, posY: Double) {
        sendPointer(
            PointerSample(kind: "axis", posX: posX, posY: posY, dx: dx, dy: dy), note: true)
    }

    func pointerCrossing(entered: Bool, posX: Double, posY: Double) {
        sendPointer(
            PointerSample(kind: entered ? "enter" : "leave", posX: posX, posY: posY), note: false)
    }

    func keyEvent(virtualCode: UInt16, down: Bool) {
        let code = GuiKeymap.evdev(for: virtualCode)
        guard code != GuiKeymap.keyReserved else { return }
        let now = GuiClock.nowNs()
        pendingInput = ("key", now)
        let key = GuiKey(win: win, keycode: code, state: down ? 1 : 0, tHostNs: now)
        if let payload = try? GuiProto.encode(key) {
            channel.send(type: GuiType.key.rawValue, flags: 0, payload: payload)
        }
    }

    private func sendPointer(_ sample: PointerSample, note: Bool) {
        assert(!sample.kind.isEmpty, "pointer kind must not be empty")
        let now = GuiClock.nowNs()
        if note { pendingInput = (sample.kind, now) }
        let pointer = GuiPointer(
            win: win, kind: sample.kind, posX: sample.posX, posY: sample.posY,
            button: sample.button, state: sample.state, dx: sample.dx, dy: sample.dy, tHostNs: now)
        if let payload = try? GuiProto.encode(pointer) {
            channel.send(type: GuiType.pointer.rawValue, flags: 0, payload: payload)
        }
    }
}
