import ConstellationCore
import SwiftUI

/// A sample session tile, drawn at `Ghost.designSize` and scaled into place by the caller.
struct GhostTileView: View {
    let ghost: Ghost
    let placement: GhostPlacement
    let settings: AppSettings

    var body: some View {
        Group {
            if placement.isSample {
                sample
            } else {
                standard
            }
        }
        .frame(width: Ghost.designSize.width, height: Ghost.designSize.height, alignment: .topLeading)
        .panelSurface(.card, edge: placement.isSample ? Palette.edge : RunStateStyle.border(for: runState, lifecycle: .unseen))
        .background {
            if !placement.isSample, let halo = RunStateStyle.halo(for: runState) {
                RoundedRectangle(cornerRadius: PanelSurface.cornerRadius, style: .continuous)
                    .fill(Palette.popover)
                    .shadow(color: halo.opacity(0.3), radius: 9)
            }
        }
        .overlay {
            if !placement.isSample, ghost.kind == .working { TravellingEdge() }
        }
        .overlay {
            if placement.isFocused {
                RoundedRectangle(cornerRadius: PanelSurface.cornerRadius + 3, style: .continuous)
                    .strokeBorder(Palette.focus, lineWidth: 2.5)
                    .padding(-3)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let count = placement.pileCount { PileCount(count: count) }
        }
        .overlay(alignment: .topLeading) {
            // The desktop's jump badge, hugging the card's corner.
            if let badge = placement.badge {
                CornerChip(tint: Palette.focus.opacity(0.45)) {
                    Text(badge).foregroundStyle(Palette.focus)
                }
                .scaleEffect(1.4)
                .offset(x: CornerChip<Text>.arcInset - 14, y: CornerChip<Text>.arcInset - 14)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .saturation(placement.isDimmed ? 0 : 1)
        .opacity(placement.isDimmed ? 0.4 : 1)
    }

    private var runState: RunState {
        switch ghost.kind {
        case .working: .working
        case .blocked: .blocked
        case .done, .terminal: .done
        }
    }

    // MARK: Standard

    /// The real tile's layout: title line, what it's doing in plain words, then its status.
    private var standard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if ghost.kind == .terminal {
                    Image(systemName: "apple.terminal").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.icon).frame(width: 12)
                } else {
                    RunGlyph(runState: runState)
                }
                if placement.provider == nil {
                    SwatchMark(swatch: placement.swatch ?? Self.swatch(for: ghost.project))
                }
                Text(ghost.title)
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if ghost.kind == .done {
                    Circle().fill(Palette.done).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .frame(height: TileMetrics.titleBarHeight)
            if ghost.kind == .terminal {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(ghost.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.mono(10)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ghost.lines[0])
                        .font(.ui(13))
                        .foregroundStyle(ghost.kind == .blocked ? Palette.ask : Palette.text)
                        .lineLimit(2)
                    Text(ghost.lines[1])
                        .font(.ui(12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text(ghost.lines[2])
                        .font(.ui(12))
                        .foregroundStyle(ghost.kind == .blocked ? Palette.ask : Palette.textTertiary)
                    Text(placement.provider.map { $0 == .claudeCode ? "claude" : "codex" } ?? "main")
                        .font(.ui(12))
                        .foregroundStyle(Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    static func swatch(for project: String) -> ProjectSwatch {
        switch project {
        case "ledger": .sage
        case "atlas": .lavender
        default: .rose
        }
    }

    // MARK: Sample

    /// What a new session starts with, from the Defaults step's choices.
    private var sample: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RunGlyph(runState: .draft, size: 11)
                SwatchMark(swatch: placement.swatch ?? .sage, size: 7)
                Text("New session").font(.ui(12, weight: .medium)).foregroundStyle(Palette.text)
                Spacer()
                Text(placement.project ?? "ledger").font(.ui(10)).foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 11)
            .padding(.top, 3)
            .frame(height: 30)
            Text("What should the agent do in \(placement.project ?? "ledger")?")
                .font(.ui(11))
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 11)
                .padding(.top, 9)
            Spacer(minLength: 0)
            SampleChips(settings: settings, project: placement.project ?? "ledger")
                .padding(.horizontal, 9)
                .padding(.bottom, 9)
        }
    }
}

/// The pills along the bottom of the sample tile.
private struct SampleChips: View {
    let settings: AppSettings
    let project: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                chip(settings.defaultProvider == .claudeCode ? "asterisk" : "chevron.left.forwardslash.chevron.right", modelTitle)
                chip("gauge.with.dots.needle.33percent", settings.defaultEffort.map { "\(AppSettings.title(ofEffort: $0)) effort" } ?? "Default effort")
            }
            HStack(spacing: 5) {
                chip("hand.raised", settings.defaultPermissionMode.title)
                chip("arrow.triangle.branch", settings.defaultNewWorktree ? "New worktree" : "In the project folder")
            }
        }
        .animation(.hover, value: settings.defaultProvider)
    }

    private var modelTitle: String {
        let model = ComposerDraft.models(for: settings.defaultProvider).first { $0.id == settings.defaultModel }?.title ?? "Default"
        return "\(settings.defaultProvider == .claudeCode ? "Claude" : "Codex") \(model)"
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.icon)
            Text(text).font(.ui(9.5, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Palette.surfaceRaised, in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.text.opacity(0.12)))
        .contentTransition(.opacity)
        .id(text)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }
}
