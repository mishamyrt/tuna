import AppKit
import AudioToolbox
import SwiftUI

@objc(CalibrationViewFactory)
final class CalibrationViewFactory: NSObject, AUCocoaUIBase {
    func interfaceVersion() -> UInt32 { 0 }

    func uiView(forAudioUnit audioUnit: AudioUnit, with size: NSSize) -> NSView? {
        let makeView = { @MainActor in
            let view = NSHostingView(rootView: Editor(model: EditorModel(unit: audioUnit)))
            view.frame = NSRect(x: 0, y: 0, width: 690, height: 468)
            return view
        }
        if Thread.isMainThread { return MainActor.assumeIsolated { makeView() } }
        return DispatchQueue.main.sync { makeView() }
    }
}
