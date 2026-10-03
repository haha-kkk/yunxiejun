import CoreGraphics

/// 只在独立 Fn 松开时确认一次手势；不读取或保存输入文字。
struct FnGesture {
    enum Transition: Equatable {
        case pressed
        case released(trigger: Bool)
    }

    private var isPressed = false
    private var isCandidate = false
    private var heldKeys: Set<Int64> = []
    private let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    mutating func flagsChanged(keyCode: Int64, flags: CGEventFlags) -> Transition? {
        let hasModifier = !flags.intersection(modifiers).isEmpty
        if isPressed && (hasModifier || keyCode != 63) { isCandidate = false }
        // Apple Fn 的键码为 63；方向键等事件也可能带 secondaryFn 标记。
        guard keyCode == 63 else { return nil }
        let pressed = flags.contains(.maskSecondaryFn)
        guard pressed != isPressed else { return nil }
        isPressed = pressed
        if pressed {
            isCandidate = !hasModifier && heldKeys.isEmpty
            return .pressed
        }
        let trigger = isCandidate && !hasModifier
        isCandidate = false
        return .released(trigger: trigger)
    }

    mutating func keyDown(_ keyCode: Int64) {
        heldKeys.insert(keyCode)
        if isPressed { isCandidate = false }
    }

    mutating func keyUp(_ keyCode: Int64) {
        heldKeys.remove(keyCode)
    }

    mutating func reset() {
        isPressed = false
        isCandidate = false
        heldKeys.removeAll()
    }
}
