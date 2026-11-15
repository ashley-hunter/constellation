import ConstellationCore
import SwiftUI

/// The run-state glyphs: ○ draft, ⠹ working (animated), ◆ blocked, ✕ failed, ✓ done.
enum Glyph {
    static let draft = "○"
    static let blocked = "◆"
    static let failed = "✕"
    static let done = "✓"
    static let interrupted = "‖"
    static let brailleFrames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏").map(String.init)
}

/// A braille spinner that cycles while visible.
struct BrailleSpinner: View {
    var color: Color = Palette.textTertiary
    var size: CGFloat = 12

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { context in
            let frame = Int(context.date.timeIntervalSinceReferenceDate / 0.08) % Glyph.brailleFrames.count
            Text(Glyph.brailleFrames[frame])
                .font(.ui(size))
                .foregroundStyle(color)
        }
    }
}

/// A chat's icon, tinted by its run state: a speech bubble, with a question in it while it waits on
/// you and an exclamation when it failed, and a spinner while it works.
struct RunGlyph: View {
    let runState: RunState
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch runState {
            case .preparing, .working:
                BrailleSpinner(color: RunStateStyle.color(for: runState), size: size)
            default:
                Image(systemName: Self.symbol(for: runState))
                    .font(.system(size: size - 1, weight: .medium))
                    .foregroundStyle(RunStateStyle.color(for: runState))
            }
        }
        .frame(width: size, alignment: .center)
        .accessibilityLabel(RunStateStyle.label(for: runState))
    }

    static func symbol(for runState: RunState) -> String {
        switch runState {
        case .blocked: "questionmark.bubble"
        case .failed: "exclamationmark.bubble"
        default: "bubble.left"
        }
    }
}

/// A project's colour square.
/// A project's colour as a dot like a window's buttons: its hue made vivid, a touch deeper at the
/// top and lit from within at the bottom, inside a thin bright rim of its own colour.
struct SwatchMark: View {
    let swatch: ProjectSwatch
    var size: CGFloat = 10

    var body: some View {
        let colour = Palette.vivid(swatch)
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        shape
            .fill(colour.mix(with: .black, by: 0.04))
            .overlay {
                // The light from within, rising from the bottom edge.
                shape.fill(RadialGradient(
                    colors: [colour.mix(with: .white, by: 0.32), colour.opacity(0)],
                    center: UnitPoint(x: 0.5, y: 0.95), startRadius: 0, endRadius: size * 0.7
                ))
            }
            .overlay {
                // The rim, brightest where the light catches it top and bottom.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [colour.mix(with: .white, by: 0.5), colour.mix(with: .white, by: 0.12), colour.mix(with: .white, by: 0.55)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: max(0.75, size * 0.07)
                )
            }
            .frame(width: size, height: size)
    }
}

/// A project's mark: its icon (see `ProjectIcon`) in a small rounded square, or its colour when
/// it has none.
struct ProjectMark: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var size: CGFloat = 13

    var body: some View {
        if let icon = model.projectIcons[project.id] {
            let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.text.opacity(0.14), lineWidth: 0.5))
        } else {
            // A touch smaller than an icon, as a solid colour weighs more.
            SwatchMark(swatch: project.swatch, size: size * 0.8)
                .frame(width: size, height: size)
        }
    }
}
