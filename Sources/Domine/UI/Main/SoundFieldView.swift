import SwiftUI

/// What the Surround sliders do, drawn on the stage under the cards.
/// Width is the band in front between the L and R sources, Surround is how
/// strongly the ambience pair behind the listener shows, Rotation turns the
/// whole field, and Orbit spins it at the orbit rate. Matches the kernel's
/// sources (DomineSurround.h): L at -width, R at +width, ambience at
/// -110 and +110, all offset by rotation plus the orbit phase.
struct SoundFieldView: View {
    var controls: SurroundControls
    var layout: StageLayout

    /// Ambience source azimuth, DOMINE_SURROUND_REAR_AZ.
    static let rearAzimuth: Double = 110

    @State private var orbit = OrbitClock()

    var body: some View {
        TimelineView(.animation(paused: controls.orbitRate <= 0)) { timeline in
            let phase = orbit.phase(at: timeline.date, turnsPerSecond: controls.orbitRate,
                                    resets: controls.orbitResetCount)
            Canvas { context, _ in
                draw(in: &context, field: controls.rotation + phase)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, field: Double) {
        let radius = layout.guideRadius
        let accent = Color.accentColor
        let width = controls.width

        // Width: a band between L and R.
        context.stroke(arc(from: field - width, to: field + width, radius: radius),
                       with: .color(accent.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 8, lineCap: .round))
        dot(in: &context, "L", azimuth: field - width, radius: radius, color: accent, opacity: 1)
        dot(in: &context, "R", azimuth: field + width, radius: radius, color: accent, opacity: 1)

        // Surround: the ambience pair behind, as strong as the level.
        let level = min(max(controls.level, 0), 1)
        guard level > 0.005 else { return }
        context.stroke(arc(from: field + Self.rearAzimuth, to: field + 360 - Self.rearAzimuth, radius: radius),
                       with: .color(accent.opacity(0.35 * level)),
                       style: StrokeStyle(lineWidth: 2 + 6 * level, lineCap: .round, dash: [2, 6]))
        dot(in: &context, nil, azimuth: field - Self.rearAzimuth, radius: radius, color: accent, opacity: level)
        dot(in: &context, nil, azimuth: field + Self.rearAzimuth, radius: radius, color: accent, opacity: level)
    }

    /// A clockwise arc on the stage from one azimuth to another.
    private func arc(from start: Double, to end: Double, radius: CGFloat) -> Path {
        Path { path in
            let steps = max(2, Int(abs(end - start) / 3))
            for i in 0...steps {
                let azimuth = start + (end - start) * Double(i) / Double(steps)
                let p = layout.point(azimuth: azimuth, radius: radius)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
    }

    private func dot(in context: inout GraphicsContext, _ label: String?, azimuth: Double,
                     radius: CGFloat, color: Color, opacity: Double) {
        let center = layout.point(azimuth: azimuth, radius: radius)
        let size: CGFloat = label == nil ? 10 : 16
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        context.fill(Circle().path(in: rect), with: .color(color.opacity(opacity)))
        guard let label else { return }
        context.draw(Text(label).font(.caption2.weight(.bold)).foregroundStyle(.white), at: center)
    }
}

/// The orbit phase for drawing, integrated from the rate so a slider move
/// does not make the field jump. Reset with the Reset button and at rate 0,
/// as the kernel does.
@MainActor
final class OrbitClock {
    private var degrees: Double = 0
    private var last: Date?
    private var resets = 0

    func phase(at date: Date, turnsPerSecond rate: Double, resets count: Int) -> Double {
        defer { last = date }
        if count != resets || rate <= 0 {
            resets = count
            degrees = 0
            return 0
        }
        if let last { degrees += rate * 360 * min(max(date.timeIntervalSince(last), 0), 0.25) }
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        return degrees
    }
}
