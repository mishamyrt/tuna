import AppKit
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

let bandCount = Int(ACUserBands)

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var config = ACConfig()
    @Published private(set) var plot = CurvePlot()
    @Published private(set) var rate = 44_100.0
    @Published private(set) var clipping = false
    @Published var error: String?
    @Published var selection: Int? {
        didSet {
            if selection != oldValue { updateCurves() }
        }
    }
    @Published var editChannels: UInt32 = 3

    private let unit: AudioUnit
    private var calculatingCurves = false
    private var needsCurveUpdate = false
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
        var edit = ACConfigEdit(original: config, updated: candidate)
        let result = AudioUnitSetProperty(unit, UInt32(ACConfigEditProperty), kAudioUnitScope_Global, 0,
                                          &edit, UInt32(MemoryLayout<ACConfigEdit>.size))
        if result == noErr {
            config = candidate
            updateCurves()
        } else {
            if result == ACConfigChanged {
                refresh()
                error = "The host changed the settings. Apply your edit again."
                return
            }
            error = "The audio effect couldn’t apply the settings (\(result))."
        }
    }

    private func updateCurves() {
        if calculatingCurves {
            needsCurveUpdate = true
            return
        }
        calculatingCurves = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self, config, rate, selection] in
            let result = CurvePlot.calculate(config: config, rate: rate, selection: selection)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.plot = result
                self.calculatingCurves = false
                if self.needsCurveUpdate {
                    self.needsCurveUpdate = false
                    self.updateCurves()
                }
            }
        }
    }
}
