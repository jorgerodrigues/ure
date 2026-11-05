import SwiftUI

// A job's state as a small pill, as on the "2 Job" and "4 Watch" artboards. A job In progress
// or Waiting has the accent colour and a dot. A done job is grey with a tick. On the job page the
// pill is the state pop-up, with the pop-up's arrows after the state.
struct JobStagePill: View {
    let stage: JobStage
    var showsIndicator = false

    var body: some View {
        HStack(spacing: stage.isOpen ? JobPillLayout.spacing : JobPillLayout.tickSpacing) {
            if stage.isOpen {
                Circle().fill(Color.accentColor)
                    .frame(width: JobPillLayout.dotSize, height: JobPillLayout.dotSize)
            } else {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
            }
            Text(stage.rawValue)
                .font(.system(size: PageLayout.pillTextSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            if showsIndicator {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .foregroundStyle(
            stage.isOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
        )
        .padding(.leading, JobPillLayout.leading)
        .padding(
            .trailing, showsIndicator ? JobPillLayout.indicatorTrailing : JobPillLayout.leading
        )
        .frame(height: JobPillLayout.height)
        .background(background, in: Capsule())
    }

    private var background: Color {
        if stage.isOpen { return Color.accentColor.opacity(0.1) }
        return Color(nsColor: .quaternarySystemFill)
    }
}

// Values from the "2 Job" artboard on the Paper page "Rework · Simple".
private enum JobPillLayout {
    static let height: CGFloat = 22
    static let leading: CGFloat = 9
    static let indicatorTrailing: CGFloat = 8
    static let spacing: CGFloat = 6
    static let tickSpacing: CGFloat = 4
    static let dotSize: CGFloat = 6
}
