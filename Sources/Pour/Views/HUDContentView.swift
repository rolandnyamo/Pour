import DesignKit
import SwiftUI

/// The floating HUD's content: a live waveform driven by `model.level`.
struct HUDContentView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: PourSpace.xs) {
            HStack(spacing: PourSpace.xs) {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                Text(statusTitle)
                    .font(PourFont.caption())
                    .foregroundStyle(accent)
                Spacer()
                if model.dictationState == .capturing {
                    Text(microphoneLabel)
                        .font(PourFont.mono(9.5))
                        .foregroundStyle(model.level < 0.08 ? PourColor.warning : PourColor.textDim)
                }
            }

            if model.dictationState == .capturing {
                Waveform(model: model).frame(height: 38)
                Text(model.preview.isEmpty ? "Speak naturally — say “literal” to protect a command." : model.preview)
                    .font(PourFont.callout()).foregroundStyle(PourColor.textMuted).lineLimit(2)
            } else if model.dictationState == .idle {
                HStack(spacing: PourSpace.xs) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PourColor.success)
                    Text("Ready for the next dictation")
                        .font(PourFont.callout()).foregroundStyle(PourColor.textMuted)
                }
                .frame(maxWidth: .infinity)
            } else {
                ProgressView().controlSize(.small).tint(accent).frame(maxWidth: .infinity)
                Text(detail).font(PourFont.callout()).foregroundStyle(PourColor.textMuted).lineLimit(1)
            }
        }
        .padding(.horizontal, PourSpace.lg)
        .padding(.vertical, PourSpace.md)
        .background(PourColor.surfacePanel.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: PourRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PourRadius.lg, style: .continuous)
                .strokeBorder(PourColor.borderStrong, lineWidth: PourBorder.hairline)
        )
        .pourShadow(model.dictationState == .capturing ? .glowAmber : .glowBlue)
    }

    private var statusTitle: String {
        switch model.dictationState {
        case .capturing: "Listening"
        case .finishing: "Transcribing"
        case .refining: "Refining"
        case .injecting: "Inserted"
        default: "Inserted"
        }
    }

    private var detail: String {
        switch model.dictationState {
        case .finishing: "Finalizing the on-device transcript…"
        case .refining: "Removing fillers and applying your writing profile…"
        case .injecting: "Text delivered — use Undo in Pour if it changed too much."
        default: "Text delivered."
        }
    }

    private var accent: Color {
        switch model.dictationState {
        case .capturing: PourColor.amber
        case .finishing: PourColor.blue400
        case .refining: PourColor.violet
        case .injecting, .idle: PourColor.success
        default: PourColor.textMuted
        }
    }

    private var symbol: String {
        switch model.dictationState {
        case .capturing: "waveform"
        case .finishing: "text.bubble"
        case .refining: "wand.and.sparkles"
        case .injecting, .idle: "checkmark.circle.fill"
        default: "cup.and.saucer"
        }
    }

    private var microphoneLabel: String {
        if model.level < 0.08 { return "MIC LOW" }
        if model.level > 0.92 { return "MIC LOUD" }
        return "MIC GOOD"
    }
}

/// Level-reactive bars, each with a fixed phase offset so the group ripples rather
/// than pumping in unison.
///
/// Takes `model` itself, not a `level: Float` snapshot — this view is hosted in a
/// bare `NSPanel` outside any normal SwiftUI window scene, where there's no guarantee
/// `HUDContentView.body` re-invokes on every Observation-tracked change to a value
/// merely passed down into a child view's `let`. Reading `model.level` fresh inside
/// the `TimelineView` closure — which ticks on its own schedule regardless of
/// Observation — guarantees every frame reflects the live level instead of rippling
/// around whatever value happened to be captured at the first render.
private struct Waveform: View {
    let model: AppModel

    private static let barCount = 20
    private static let phases: [Double] = (0..<barCount).map { index in
        // Irrational multiplier keeps the offsets from lining up into a visible period.
        (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let level = model.level
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    let bar = bar(for: index, at: t, level: level)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(barColor(fraction: bar.fraction))
                        .frame(width: 4, height: bar.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bar(for index: Int, at time: TimeInterval, level: Float) -> (height: CGFloat, fraction: CGFloat) {
        let floorHeight: CGFloat = 3
        let phase = Self.phases[index]
        let wave = sin(time * 6.0 + phase * .pi * 2)
        let amplitude = CGFloat(max(0.05, level))
        // The ripple rides on top of the level so bars still breathe during quiet
        // passages instead of flatlining between buffers.
        let scaled = max(0, amplitude * (0.55 + 0.45 * CGFloat(wave)))
        return (floorHeight + scaled * 39, min(1, scaled))
    }

    /// Amber at rest, popping straight to Blue 400 — the brand's "bright accent, glow
    /// edge" token — once a bar crosses the threshold. No continuous blend: amber
    /// (~45° hue) and cyan (~200° hue) sit almost opposite on the wheel, so a smooth
    /// RGB crossfade between them passes straight through a muddy green midpoint.
    /// A hard cutover keeps both colors clean and reads as a genuine "pop."
    private func barColor(fraction: CGFloat) -> Color {
        fraction > 0.55 ? PourColor.blue400 : PourColor.amber
    }
}
