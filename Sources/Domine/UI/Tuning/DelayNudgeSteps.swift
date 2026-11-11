/// How far the delay nudge buttons and arrow keys move the stereo delay.
/// Saved in `SettingsStore.delayNudgeSteps`.
enum DelayNudgeSteps: String, CaseIterable, Identifiable, Sendable {
    case fine, normal, coarse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fine: "Fine"
        case .normal: "Normal"
        case .coarse: "Coarse"
        }
    }

    /// Plain arrow key and the inner buttons, in ms.
    var small: Double {
        switch self {
        case .fine: 0.5
        case .normal: 1
        case .coarse: 5
        }
    }

    /// Shift-arrow and the outer buttons, in ms.
    var large: Double {
        switch self {
        case .fine: 2
        case .normal: 5
        case .coarse: 20
        }
    }

    /// The four buttons from left to right.
    var buttonSteps: [Double] { [-large, -small, small, large] }

    /// "Fine (0.5 and 2 ms)" in the menu.
    var menuTitle: String {
        "\(title) (\(TuningState.msText(small)) and \(TuningState.msText(large)) ms)"
    }
}
