import AVFoundation
import AppKit
import CoreMedia
import SwiftUI

/// Turns Annex-B H.264/H.265 access units into CMSampleBuffers that AVSampleBufferDisplayLayer can decode.
final class AnnexBConverter {
    enum Codec: String { case h264 = "H.264", hevc = "H.265" }

    private(set) var codec: Codec?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [[UInt8]] = []
    private var waitingForKeyFrame = true

    func reset() {
        format = nil; parameterSets = []; waitingForKeyFrame = true
    }

    /// Splits an Annex-B bytestream into NAL units (without start codes).
    static func nalUnits(_ d: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var i = 0, start = -1
        let n = d.count
        while i + 2 < n {
            if d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start && d[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(d[start..<end]) }
                }
                i += 3; start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < n { units.append(d[start..<n]) }
        return units
    }

    private static func detectCodec(_ units: [ArraySlice<UInt8>]) -> Codec? {
        for u in units {
            guard let b = u.first else { continue }
            let hevcType = (b >> 1) & 0x3F
            if b & 0x80 == 0, [32, 33, 34].contains(hevcType), u.count > 1 { return .hevc }
            if [7, 8].contains(b & 0x1F) { return .h264 }
        }
        return nil
    }

    func sampleBuffer(from annexB: [UInt8], isKeyFrame: Bool) -> CMSampleBuffer? {
        let units = Self.nalUnits(annexB)
        if codec == nil { codec = Self.detectCodec(units) }
        guard let codec else { return nil }

        var sets: [[UInt8]] = []
        var payload: [UInt8] = []
        var hasIDR = false
        for u in units {
            guard let b = u.first else { continue }
            switch codec {
            case .h264:
                let t = b & 0x1F
                if t == 7 || t == 8 { sets.append(Array(u)); continue }
                if t == 9 { continue }
                if t == 5 { hasIDR = true }
            case .hevc:
                let t = (b >> 1) & 0x3F
                if t == 32 || t == 33 || t == 34 { sets.append(Array(u)); continue }
                if t == 35 { continue }
                if (16...21).contains(t) { hasIDR = true }
            }
            var len = UInt32(u.count).bigEndian
            withUnsafeBytes(of: &len) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: u)
        }

        if !sets.isEmpty && sets != parameterSets {
            if let f = makeFormat(codec, sets) { format = f; parameterSets = sets }
        }
        guard let format, !payload.isEmpty else { return nil }
        let key = isKeyFrame || hasIDR
        if waitingForKeyFrame {
            guard key else { return nil }
            waitingForKeyFrame = false
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: payload.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: payload, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: payload.count) == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
            first[kCMSampleAttachmentKey_NotSync] = !key
        }
        return sample
    }

    private func makeFormat(_ codec: Codec, _ sets: [[UInt8]]) -> CMVideoFormatDescription? {
        let wanted: [UInt8]
        switch codec {
        case .h264: wanted = [7, 8]
        case .hevc: wanted = [32, 33, 34]
        }
        // Parameter sets must be passed in VPS/SPS/PPS order, one of each.
        let ordered: [[UInt8]] = wanted.compactMap { type in
            sets.first { codec == .h264 ? ($0[0] & 0x1F) == type : (($0[0] >> 1) & 0x3F) == type }
        }
        guard ordered.count == wanted.count else { return nil }

        let copies = ordered.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = ordered.map { $0.count }

        var out: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: ordered.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: ordered.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &out)
        }
        return status == noErr ? out : nil
    }
}

/// Hosts an AVSampleBufferDisplayLayer (hardware decode) with digital zoom + pan.
/// Pinch or scroll to zoom, drag to pan when zoomed, double-click to reset.
final class VideoLayerView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero          // content offset, in view points
    private var panStart = CGPoint.zero
    private var dragOrigin = CGPoint.zero
    private var panning = false

    /// Reports the current zoom factor (1 = fit) so the UI can show an indicator.
    var onZoomChange: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        applyTransform()
    }

    private func applyTransform() {
        clampPan()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.setAffineTransform(CGAffineTransform(translationX: pan.x, y: pan.y).scaledBy(x: zoom, y: zoom))
        CATransaction.commit()
    }

    /// Keep the zoomed picture covering the view so panning never reveals black bars.
    private func clampPan() {
        let maxX = max(0, (zoom - 1) * bounds.width / 2)
        let maxY = max(0, (zoom - 1) * bounds.height / 2)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
    }

    func setZoom(_ newValue: CGFloat) {
        let clamped = min(max(newValue, 1), 8)
        guard clamped != zoom else { return }
        zoom = clamped
        if zoom == 1 { pan = .zero }
        applyTransform()
        onZoomChange?(zoom)
    }

    func resetZoom() { pan = .zero; setZoom(1) }

    // MARK: - Gestures

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification))
    }

    override func scrollWheel(with event: NSEvent) {
        // Scroll to zoom (works with a mouse wheel too).
        setZoom(zoom * (1 + event.scrollingDeltaY * 0.006))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { resetZoom(); return }
        if zoom > 1 {
            panning = true
            panStart = pan
            dragOrigin = convert(event.locationInWindow, from: nil)
        } else {
            super.mouseDown(with: event) // let the window move by its background
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard panning else { super.mouseDragged(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        pan = CGPoint(x: panStart.x + (p.x - dragOrigin.x), y: panStart.y + (p.y - dragOrigin.y))
        applyTransform()
    }

    override func mouseUp(with event: NSEvent) {
        if panning { panning = false } else { super.mouseUp(with: event) }
    }
}

/// Receives frames from any thread and shows them.
final class VideoRenderer {
    let view = VideoLayerView()
    private let converter = AnnexBConverter()
    private let queue = DispatchQueue(label: "camview.render")

    var codecName: String? { converter.codec?.rawValue }

    /// Decoder health for diagnostics logs (no image content).
    var statusDescription: String {
        let layer = view.displayLayer
        switch layer.status {
        case .rendering: return "rendering"
        case .failed: return "failed: \(layer.error?.localizedDescription ?? "?")"
        default: return "unknown"
        }
    }

    func enqueue(_ annexB: [UInt8], isKeyFrame: Bool) {
        queue.async { [self] in
            let layer = view.displayLayer
            if layer.status == .failed {
                layer.flush()
                converter.reset()
            }
            guard let sample = converter.sampleBuffer(from: annexB, isKeyFrame: isKeyFrame) else { return }
            layer.enqueue(sample)
        }
    }

    func clear() {
        queue.async { [self] in
            view.displayLayer.flushAndRemoveImage()
            converter.reset()
        }
    }
}

struct VideoSurface: NSViewRepresentable {
    let renderer: VideoRenderer
    var onZoom: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> VideoLayerView {
        renderer.view.onZoomChange = onZoom
        return renderer.view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        nsView.onZoomChange = onZoom
    }
}
