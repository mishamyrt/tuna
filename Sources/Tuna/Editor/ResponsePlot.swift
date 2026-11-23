import SwiftUI

private let graphPoints = 512

struct Curve {
    let values: [Float]
    let color: Color
    let reference: Bool
}

struct CurvePlot {
    var curves: [Curve] = []
    var bandShape: [Float]?
    var headroom: Float = 0

    static func calculate(config: ACConfig, rate: Double, selection: Int?) -> CurvePlot {
        var config = config
        func response(_ config: ACConfig, channel: Int, profileOnly: Bool = false,
                      offset: Float = 0) -> [Float] {
            var config = config
            var points = [Float](repeating: 0, count: graphPoints)
            points.withUnsafeMutableBufferPointer { values in
                ac_curve(&config, rate, UInt32(channel), profileOnly, offset, values.baseAddress, values.count)
            }
            return points
        }

        let selected = selection.flatMap { index in
            let band = ac_user_band(&config, index)
            return band.channels == 0 ? nil : (index, band)
        }
        var referenceConfig = config
        if let (index, _) = selected {
            ac_set_user_band(&referenceConfig, index, ACBand())
        }
        let colors: [Color] = [.cyan, .orange]
        let attenuation = ac_headroom(&config, rate)
        let curves = [true, false].flatMap { reference in
            (0..<2).map { channel in
                let profileOnly = reference && selected == nil
                let source = reference ? referenceConfig : config
                let points = response(source, channel: channel, profileOnly: profileOnly,
                                      offset: profileOnly ? 0 : attenuation)
                return Curve(values: points, color: colors[channel], reference: reference)
            }
        }
        let bandShape = selected.map { _, band in
            var solo = ACConfig()
            solo.wet = 1
            var band = band
            band.channels = 1
            ac_set_user_band(&solo, 0, band)
            return response(solo, channel: 0)
        }
        return CurvePlot(curves: curves, bandShape: bandShape, headroom: attenuation)
    }
}

struct ResponsePlot: View {
    @ObservedObject var model: EditorModel
    let nodes: [Int]
    private let gainLimit = 24.0

    var body: some View {
        let curves = model.plot.curves
        let bandShape = model.plot.bandShape
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
