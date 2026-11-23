import SwiftUI

struct Editor: View {
    @ObservedObject var model: EditorModel

    private var nodes: [Int] { (0..<bandCount).filter { model.band($0).channels != 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tuna").font(.title3.weight(.semibold))
                    Text(model.name.isEmpty ? "No calibration profile" : model.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 10)
                Picker("Target Curve", selection: Binding(
                    get: { model.config.target },
                    set: { value in model.change { $0.target = value } }
                )) {
                    Text("Flat").tag(UInt32(ACTargetFlat))
                    Text("Harman").tag(UInt32(ACTargetHarman))
                    Text("Marshall-style").tag(UInt32(ACTargetMarshall))
                }
                .fixedSize()
                Button("Import Profile…", action: model.importProfile)
            }

            HStack(spacing: 14) {
                Picker("Filter", selection: Binding(
                    get: { model.config.mode },
                    set: { value in model.change { $0.mode = value } }
                )) {
                    Text("Zero Latency").tag(UInt32(0))
                    Text("Mixed").tag(UInt32(1))
                    Text("Linear Phase").tag(UInt32(2))
                }
                .fixedSize()
                Text(String(format: "%.2f ms", model.latencyMS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Filter latency")
                Spacer()
                Text("Left").foregroundStyle(.cyan)
                Text("Right").foregroundStyle(.orange)
                if model.plot.bandShape != nil {
                    Text("Band shape").foregroundStyle(.purple)
                    Text("Dashed: without band").foregroundStyle(.secondary)
                } else {
                    Text("Dashed: profile").foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            calibrationRange

            ResponsePlot(model: model, nodes: nodes)
                .frame(minHeight: 190, idealHeight: 227, maxHeight: .infinity)

            HStack {
                Button {
                    model.addBand()
                } label: {
                    Label("Add Band", systemImage: "plus")
                }
                .disabled(nodes.count == bandCount)
                Picker("New band", selection: $model.editChannels) {
                    Text("L").tag(UInt32(1))
                    Text("R").tag(UInt32(2))
                    Text("Link").tag(UInt32(3))
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 113)
                Spacer()
                ForEach(nodes, id: \.self) { index in
                    Button("\(index + 1)") { model.selection = index }
                        .buttonStyle(.bordered)
                        .tint(model.selection == index ? .accentColor : .secondary)
                        .accessibilityLabel("Select band \(index + 1)")
                }
            }
            if let index = model.selection, model.band(index).channels != 0 {
                bandControls(index).id(index)
            } else {
                Text("Select a band to edit its values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 25)
            }

            Divider()
            HStack(spacing: 16) {
                Toggle("Time alignment", isOn: Binding(
                    get: { model.config.alignment != 0 },
                    set: { enabled in model.change { $0.alignment = enabled ? 1 : 0 } }
                ))
                .help(String(format: "Exported delays: L %.2f ms, R %.2f ms",
                             model.config.left.delay_ms, model.config.right.delay_ms))
                Toggle("Safe headroom", isOn: Binding(
                    get: { model.config.safe_headroom != 0 },
                    set: { enabled in model.change { $0.safe_headroom = enabled ? 1 : 0 } }
                ))
                Text(String(format: "%.1f dB", model.plot.headroom))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if model.clipping {
                    Label("Output overload", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption.weight(.semibold))
                }
                HStack(spacing: 6) {
                    Slider(value: Binding(
                        get: { model.config.wet },
                        set: { value in model.change { $0.wet = value } }
                    ), in: 0...1, step: 0.01) {
                        Text("Dry/Wet")
                    }
                    .accessibilityLabel("Dry/Wet")
                    Text(model.config.wet.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .frame(width: 172)
            }
        }
        .padding(18)
        .frame(minWidth: 620, idealWidth: 690, minHeight: 440, idealHeight: 468)
        .task { @MainActor in
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .alert("Tuna", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var calibrationRange: some View {
        let limited = model.config.range_enabled != 0
        let low = model.config.range_low == 0 ? 200 : model.config.range_low
        let high = model.config.range_high == 0 ? 5000 : model.config.range_high
        return HStack(spacing: 8) {
            Toggle("Limit Calibration Range", isOn: Binding(
                get: { model.config.range_enabled != 0 },
                set: { enabled in
                    model.change {
                        if enabled && $0.range_low == 0 {
                            $0.range_low = 200
                            $0.range_high = 5000
                        }
                        $0.range_enabled = enabled ? 1 : 0
                    }
                }
            ))
            .help("Limits the imported profile. Target Curve and manual EQ stay active at all frequencies.")
            HStack(spacing: 4) {
                NumberField(label: "Lower calibration frequency", value: Float(low),
                            range: 20...Float(high - 1), digits: 0, live: false) { value in
                    guard model.config.range_enabled != 0 else { return }
                    model.change { $0.range_low = min(UInt32(value.rounded()), $0.range_high - 1) }
                }
                .frame(width: 59)
                Text("–").accessibilityHidden(true)
                NumberField(label: "Upper calibration frequency", value: Float(high),
                            range: Float(low + 1)...20_000, digits: 0, live: false) { value in
                    guard model.config.range_enabled != 0 else { return }
                    model.change { $0.range_high = max(UInt32(value.rounded()), $0.range_low + 1) }
                }
                .frame(width: 59)
                Text("Hz").foregroundStyle(.secondary)
            }
            .disabled(!limited)
            Spacer()
        }
        .font(.caption)
    }

    private func bandControls(_ index: Int) -> some View {
        HStack(spacing: 8) {
            Picker("Type", selection: Binding(
                get: { model.band(index).kind },
                set: { value in model.edit(index) { $0.kind = value } }
            )) {
                Text("Bell").tag(UInt32(0))
                Text("Low shelf").tag(UInt32(1))
                Text("High shelf").tag(UInt32(2))
            }
            .labelsHidden()
            .frame(width: 102)
            Picker("Channel", selection: Binding(
                get: { model.band(index).channels },
                set: { value in model.edit(index) { $0.channels = value } }
            )) {
                Text("Left").tag(UInt32(1))
                Text("Right").tag(UInt32(2))
                Text("Linked").tag(UInt32(3))
            }
            .labelsHidden()
            .frame(width: 79)

            number("Hz", label: "Frequency", index: index, key: \.frequency,
                   range: 20...Float(model.upperFrequency), digits: 0)
            number("dB", label: "Gain", index: index, key: \.gain, range: -24...24, digits: 1)
            number("Q", label: "Q", index: index, key: \.q, range: 0.1...20, digits: 2)
            Spacer(minLength: 0)
            Button(role: .destructive) { model.removeBand(index) } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Remove band")
        }
        .frame(height: 25)
    }

    private func number(_ unit: String, label: String, index: Int,
                        key: WritableKeyPath<ACBand, Float>, range: ClosedRange<Float>,
                        digits: Int) -> some View {
        HStack(spacing: 3) {
            NumberField(label: label, value: model.band(index)[keyPath: key],
                            range: range, digits: digits) { value in
                model.edit(index) { $0[keyPath: key] = value }
            }
            .frame(width: 59)
            Text(unit).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
