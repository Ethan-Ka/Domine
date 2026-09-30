/// The first-run checklist, in display order.
struct WelcomeState: Equatable, Sendable {
    var steps: [WelcomeStep] = WelcomeStep.Kind.allCases.map { WelcomeStep(kind: $0, isDone: false) }

    var allDone: Bool { steps.allSatisfy(\.isDone) }

    func isDone(_ kind: WelcomeStep.Kind) -> Bool {
        steps.first { $0.kind == kind }?.isDone ?? false
    }

    mutating func setDone(_ kind: WelcomeStep.Kind, _ done: Bool = true) {
        guard let index = steps.firstIndex(where: { $0.kind == kind }) else { return }
        steps[index].isDone = done
    }
}
