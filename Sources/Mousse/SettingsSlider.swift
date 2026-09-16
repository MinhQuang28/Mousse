import SwiftUI

/// One labelled slider row for the grouped Settings forms: title and live value on one line, the
/// slider with its end labels beneath. Built by hand rather than with `Slider`'s own `label:` /
/// `step:` because, in a grouped `Form`, the label renders as a second row (duplicating the
/// title) and `step:` draws a tick per step — 30–60 ticks read as a grey bar. Snapping happens
/// in the binding instead so the stored value still lands on the step grid.
struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var minLabel = ""
    var maxLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if !minLabel.isEmpty { Text(minLabel).font(.caption).foregroundStyle(.secondary) }
                Slider(value: snapped, in: range).labelsHidden()
                if !maxLabel.isEmpty { Text(maxLabel).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var snapped: Binding<Double> {
        Binding(
            get: { value },
            set: { raw in
                let stepped = (raw / step).rounded() * step
                value = min(max(stepped, range.lowerBound), range.upperBound)
            })
    }
}
