import AppKit
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

@objc(CalibrationViewFactory)
final class CalibrationViewFactory: NSObject, AUCocoaUIBase {
    func interfaceVersion() -> UInt32 { 0 }

    func uiView(forAudioUnit audioUnit: AudioUnit, with size: NSSize) -> NSView? {
        let view = NSHostingView(rootView: Editor(model: EditorModel(unit: audioUnit)))
        view.frame = NSRect(x: 0, y: 0, width: 690, height: 468)
        return view
    }
}

private let graphPoints = 512
private let bandCount = Int(ACUserBands)

private struct Curve {
    let values: [Float]
    let color: Color
    let reference: Bool
}

private final class EditorModel: ObservableObject {
    @Published private(set) var config = ACConfig()
    @Published private(set) var curves: [Curve] = []
    @Published private(set) var bandShape: [Float]?
    @Published private(set) var rate = 44_100.0
    @Published private(set) var headroom: Float = 0
    @Published private(set) var clipping = false
    @Published var error: String?
    @Published var selection: Int? {
        didSet {
            if selection != oldValue { updateCurves() }
        }
    }
    @Published var editChannels: UInt32 = 3

    private let unit: AudioUnit
    private var lastClip = Date.distantPast

    init(unit: AudioUnit) {
        self.unit = unit
        refresh()
    }

    var name: String {
        withUnsafeBytes(of: config.name) {
            let bytes = $0.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    var upperFrequency: Double { min(20_000, rate * 0.49) }
    var latencyMS: Double { 1000 * Double(ac_latency(config.mode, rate)) / rate }

    func band(_ index: Int) -> ACBand {
        withUnsafePointer(to: config) { ac_user_band($0, index) }
    }

    func refresh() {
        var status = ACStatus()
        var statusSize = UInt32(MemoryLayout<ACStatus>.size)
        var needsUpdate = false
        if AudioUnitGetProperty(unit, UInt32(ACStatusProperty), kAudioUnitScope_Global, 0,
                                &status, &statusSize) == noErr {
            if status.sample_rate != rate {
                rate = status.sample_rate
                needsUpdate = true
            }
            if status.peak > 1 {
                lastClip = Date()
            }
            let clipped = Date().timeIntervalSince(lastClip) < 1.25
            if clipping != clipped { clipping = clipped }
        }

        var current = ACConfig()
        var configSize = UInt32(MemoryLayout<ACConfig>.size)
        if AudioUnitGetProperty(unit, UInt32(ACConfigProperty), kAudioUnitScope_Global, 0,
                                &current, &configSize) == noErr,
           !withUnsafeBytes(of: current, { newBytes in
               withUnsafeBytes(of: config) { newBytes.elementsEqual($0) }
           }) {
            config = current
            if let selection, band(selection).channels == 0 { self.selection = nil }
            needsUpdate = true
        }
        if needsUpdate { updateCurves() }
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Import SoundID Reference Profile"
        panel.allowedContentTypes = [UTType(filenameExtension: "tmreq") ?? .data]
        panel.message = "Choose the stereo Room EQ file exported for RME."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let limit = 64 * 1024
                if try handle.seekToEnd() > UInt64(limit) {
                    self.error = "The profile exceeds 64 KB."
                    return
                }
                try handle.seek(toOffset: 0)
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                var candidate = self.config
                let valid = url.deletingPathExtension().lastPathComponent.withCString { name in
                    data.withUnsafeBytes {
                        ac_import($0.bindMemory(to: UInt8.self).baseAddress, $0.count, name, &candidate)
                    }
                }
                if valid {
                    self.send(candidate)
                } else {
                    self.error = "Couldn’t read this preset. Export a stereo Room EQ (.tmreq) file for RME from SoundID Reference."
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func change(_ update: (inout ACConfig) -> Void) {
        var edited = config
        update(&edited)
        send(edited)
    }

    func edit(_ index: Int, _ update: (inout ACBand) -> Void) {
        var value = band(index)
        update(&value)
        change { ac_set_user_band(&$0, index, value) }
    }

    func addBand() {
        guard let index = (0..<bandCount).first(where: { band($0).channels == 0 }) else { return }
        edit(index) { $0 = ACBand(frequency: 1000, gain: 0, q: 1, kind: 0, channels: editChannels) }
        selection = index
    }

    func removeBand(_ index: Int) {
        edit(index) { $0 = ACBand() }
        selection = nil
    }

    private func send(_ candidate: ACConfig) {
        var candidate = candidate
        let result = AudioUnitSetProperty(unit, UInt32(ACConfigProperty), kAudioUnitScope_Global, 0,
                                          &candidate, UInt32(MemoryLayout<ACConfig>.size))
        if result == noErr {
            config = candidate
            updateCurves()
        } else {
            error = "The audio effect couldn’t apply the settings (\(result))."
        }
    }

    private func updateCurves() {
        var config = config
        let selected = selection.flatMap { index in
            let band = self.band(index)
            return band.channels == 0 ? nil : (index, band)
        }
        var referenceConfig = config
        if let (index, _) = selected {
            ac_set_user_band(&referenceConfig, index, ACBand())
        }
        let colors: [Color] = [.cyan, .orange]
        let attenuation = ac_headroom(&config, rate)
        curves = [true, false].flatMap { reference in
            (0..<2).map { channel in
                let profileOnly = reference && selected == nil
                let source = reference ? referenceConfig : config
                let points = response(source, channel: channel, profileOnly: profileOnly,
                                      offset: profileOnly ? 0 : attenuation)
                return Curve(values: points, color: colors[channel], reference: reference)
            }
        }
        bandShape = selected.map { _, band in
            var solo = ACConfig()
            solo.wet = 1
            var band = band
            band.channels = 1
            ac_set_user_band(&solo, 0, band)
            return response(solo, channel: 0)
        }
        headroom = attenuation
    }

    private func response(_ config: ACConfig, channel: Int, profileOnly: Bool = false,
                          offset: Float = 0) -> [Float] {
        var config = config
        var points = [Float](repeating: 0, count: graphPoints)
        points.withUnsafeMutableBufferPointer { values in
            ac_curve(&config, rate, UInt32(channel), profileOnly, offset, values.baseAddress, values.count)
        }
        return points
    }
}

private struct Editor: View {
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
                if model.bandShape != nil {
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
                Text(String(format: "%.1f dB", model.headroom))
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

private struct NumberField: View {
    let label: String
    let value: Float
    let range: ClosedRange<Float>
    let digits: Int
    var live = true
    let apply: (Float) -> Void

    @FocusState private var focused: Bool
    @State private var draft: String?

    var body: some View {
        TextField(label, text: Binding(
            get: { draft ?? value.formatted(.number.grouping(.never).precision(.fractionLength(digits))) },
            set: { text in
                draft = text
                if live, let number = parse(text), range.contains(number), number != value {
                    apply(number)
                }
            }
        ))
        .labelsHidden()
        .accessibilityLabel(label)
        .monospacedDigit()
        .focused($focused)
        .onChange(of: focused) { _, isFocused in
            if !isFocused { finish() }
        }
        .onSubmit { finish() }
    }

    private func parse(_ text: String) -> Float? {
        let normalized = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard let number = Float(normalized), number.isFinite else { return nil }
        return number
    }

    private func finish() {
        if let draft, let number = parse(draft) {
            let bounded = min(range.upperBound, max(range.lowerBound, number))
            if bounded != value { apply(bounded) }
        }
        draft = nil
    }
}

private struct ResponsePlot: View {
    @ObservedObject var model: EditorModel
    let nodes: [Int]
    private let gainLimit = 24.0

    var body: some View {
        let curves = model.curves
        let bandShape = model.bandShape
        GeometryReader { proxy in
            let plot = CGRect(x: 46, y: 12, width: max(1, proxy.size.width - 59),
                              height: max(1, proxy.size.height - 35))
            ZStack(alignment: .topLeading) {
                responseCanvas(curves: curves, bandShape: bandShape, in: plot)
                ForEach(nodes, id: \.self) { index in
                    bandNode(index, in: plot)
                }
            }
            .coordinateSpace(name: "response")
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func responseCanvas(curves: [Curve], bandShape: [Float]?, in plot: CGRect) -> some View {
        let frequencyTicks: [(Double, String)] = [
            (20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
            (1000, "1k"), (2000, "2k"), (5000, "5k"), (10_000, "10k"), (20_000, "20k")
        ]
        return Canvas { context, _ in
            for db in stride(from: -24.0, through: 24.0, by: 6.0) {
                let y = ordinate(db, in: plot)
                context.stroke(Path { line in
                    line.move(to: CGPoint(x: plot.minX, y: y))
                    line.addLine(to: CGPoint(x: plot.maxX, y: y))
                }, with: .color(.secondary.opacity(db == 0 ? 0.57 : 0.25)), lineWidth: 0.7)
                context.draw(Text("\(Int(db)) dB").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
            }
            for (frequency, label) in frequencyTicks where frequency <= model.upperFrequency {
                let x = abscissa(frequency, in: plot)
                context.stroke(Path { line in
                    line.move(to: CGPoint(x: x, y: plot.minY))
                    line.addLine(to: CGPoint(x: x, y: plot.maxY))
                }, with: .color(.secondary.opacity(0.25)), lineWidth: 0.7)
                context.draw(Text(label).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary), at: CGPoint(x: x, y: plot.maxY + 12))
            }
            var response = context
            response.clip(to: Path(plot))
            if let bandShape {
                let outline = path(bandShape, in: plot)
                var fill = outline
                fill.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
                fill.addLine(to: CGPoint(x: plot.minX, y: plot.midY))
                fill.closeSubpath()
                response.fill(fill, with: .color(.purple.opacity(0.20)))
                response.stroke(outline, with: .color(.purple), lineWidth: 1.25)
            }
            for curve in curves {
                response.stroke(path(curve.values, in: plot),
                                with: .color(curve.color.opacity(curve.reference ? 0.65 : 0.95)),
                                style: StrokeStyle(lineWidth: curve.reference ? 1 : 1.65,
                                                   dash: curve.reference ? [3, 4] : []))
            }
        }
        .accessibilityHidden(true)
    }

    private func bandNode(_ index: Int, in plot: CGRect) -> some View {
        let band = model.band(index)
        let color: Color = band.channels == 1 ? .cyan : band.channels == 2 ? .orange : .primary
        let selected = model.selection == index
        return Button { model.selection = index } label: {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 23, height: 23)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(color.opacity(0.85), lineWidth: selected ? 2 : 1) }
                .foregroundStyle(color)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Band \(index + 1)")
        .position(x: abscissa(Double(band.frequency), in: plot),
                  y: ordinate(Double(band.gain), in: plot))
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("response"))
            .onChanged { value in
                model.selection = index
                let x = min(1, max(0, Double((value.location.x - plot.minX) / plot.width)))
                let y = min(1, max(0, Double((value.location.y - plot.minY) / plot.height)))
                let frequency = 20 * pow(model.upperFrequency / 20, x)
                let gain = (1 - 2 * y) * gainLimit
                model.edit(index) {
                    $0.frequency = Float(frequency.rounded())
                    $0.gain = Float((gain * 10).rounded() / 10)
                }
            })
    }

    private func path(_ values: [Float], in plot: CGRect) -> Path {
        Path { line in
            for (index, value) in values.enumerated() {
                let x = plot.minX + plot.width * Double(index) / Double(values.count - 1)
                let point = CGPoint(x: x, y: ordinate(Double(value), in: plot))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
        }
    }

    private func abscissa(_ frequency: Double, in plot: CGRect) -> Double {
        let fraction = log(min(model.upperFrequency, max(20, frequency)) / 20) / log(model.upperFrequency / 20)
        return plot.minX + plot.width * fraction
    }

    private func ordinate(_ gain: Double, in plot: CGRect) -> Double {
        plot.midY - plot.height * gain / (2 * gainLimit)
    }
}
