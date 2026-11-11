import CoreMedia
import UIKit

/// Turns Weylus' fragmented MP4 stream (init segment, then one moof+mdat per frame) into
/// CMSampleBuffers for the hardware decoder.
/// The stream arrives in arbitrary chunks, so boxes are reassembled from a byte buffer.
final class FragmentedMP4Parser {
    private var buffer: [UInt8] = []
    private var format: CMVideoFormatDescription?
    private var nalLengthSize = 4

    var onFormat: ((CGSize) -> Void)?
    var onSample: ((CMSampleBuffer) -> Void)?

    /// Call when Weylus announces a new stream ("NewVideo").
    func reset() {
        buffer.removeAll(keepingCapacity: true)
        format = nil
    }

    func append(_ data: Data) {
        buffer.append(contentsOf: data)
        var offset = 0
        while buffer.count - offset >= 8 {
            let size32 = Self.u32(buffer, offset)
            let type = Self.fourcc(buffer, offset + 4)
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard buffer.count - offset >= 16 else { break }
                size = Int(Self.u64(buffer, offset + 8))
                header = 16
            }
            if size < header {
                // Corrupt or unsupported (size 0 = "until end of file"); start over.
                reset()
                return
            }
            guard buffer.count - offset >= size else { break }
            handle(type: type, payload: (offset + header)..<(offset + size))
            offset += size
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    private func handle(type: String, payload: Range<Int>) {
        switch type {
        case "moov":
            parseInit(payload)
        case "mdat":
            if format != nil { makeSample(payload) }
        default:
            break // ftyp, moof, ...: timing isn't needed, frames are shown as soon as they arrive
        }
    }

    // MARK: Init segment

    private func children(_ range: Range<Int>) -> [(String, Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var o = range.lowerBound
        while range.upperBound - o >= 8 {
            let size = Int(Self.u32(buffer, o))
            let type = Self.fourcc(buffer, o + 4)
            guard size >= 8, o + size <= range.upperBound else { break }
            out.append((type, (o + 8)..<(o + size)))
            o += size
        }
        return out
    }

    private func child(_ type: String, in range: Range<Int>) -> Range<Int>? {
        children(range).first { $0.0 == type }?.1
    }

    private func parseInit(_ moov: Range<Int>) {
        for (type, trak) in children(moov) where type == "trak" {
            guard let mdia = child("mdia", in: trak),
                  let minf = child("minf", in: mdia),
                  let stbl = child("stbl", in: minf),
                  let stsd = child("stsd", in: stbl),
                  stsd.count > 8 else { continue }
            // stsd: version/flags (4) + entry count (4), then sample entries
            for (entryType, entry) in children((stsd.lowerBound + 8)..<stsd.upperBound)
            where entryType == "avc1" || entryType == "avc3" {
                // VisualSampleEntry has 78 bytes of fixed fields before its child boxes
                guard entry.count > 78,
                      let avcC = child("avcC", in: (entry.lowerBound + 78)..<entry.upperBound) else { continue }
                parseAvcC(avcC)
                return
            }
        }
    }

    private func parseAvcC(_ r: Range<Int>) {
        guard r.count >= 7 else { return }
        var o = r.lowerBound
        nalLengthSize = Int(buffer[o + 4] & 0x03) + 1
        let numSPS = Int(buffer[o + 5] & 0x1f)
        o += 6
        var sets: [[UInt8]] = []
        for _ in 0..<numSPS {
            guard o + 2 <= r.upperBound else { return }
            let len = Int(Self.u16(buffer, o)); o += 2
            guard o + len <= r.upperBound else { return }
            sets.append(Array(buffer[o..<(o + len)])); o += len
        }
        guard o < r.upperBound else { return }
        let numPPS = Int(buffer[o]); o += 1
        for _ in 0..<numPPS {
            guard o + 2 <= r.upperBound else { return }
            let len = Int(Self.u16(buffer, o)); o += 2
            guard o + len <= r.upperBound else { return }
            sets.append(Array(buffer[o..<(o + len)])); o += len
        }
        guard sets.count >= 2 else { return }

        // CMVideoFormatDescriptionCreateFromH264ParameterSets wants stable pointers to every set.
        let joined = sets.flatMap { $0 }
        var offsets: [Int] = []
        var acc = 0
        for s in sets { offsets.append(acc); acc += s.count }
        var fmt: CMVideoFormatDescription?
        let status = joined.withUnsafeBufferPointer { base -> OSStatus in
            let ptrs = offsets.map { base.baseAddress! + $0 }
            let sizes = sets.map { $0.count }
            return ptrs.withUnsafeBufferPointer { p in
                sizes.withUnsafeBufferPointer { s in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: sets.count,
                        parameterSetPointers: p.baseAddress!,
                        parameterSetSizes: s.baseAddress!,
                        nalUnitHeaderLength: Int32(nalLengthSize),
                        formatDescriptionOut: &fmt
                    )
                }
            }
        }
        guard status == noErr, let fmt else { return }
        format = fmt
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        onFormat?(CGSize(width: Int(dims.width), height: Int(dims.height)))
    }

    // MARK: Frames

    private func makeSample(_ r: Range<Int>) {
        guard let format, r.count > 0 else { return }
        let len = r.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: len,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: len, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return }
        let copied = buffer.withUnsafeBufferPointer { base in
            CMBlockBufferReplaceDataBytes(
                with: base.baseAddress! + r.lowerBound, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: len
            )
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var sample: CMSampleBuffer?
        var sizes = [len]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        // No timestamps: show each frame the moment it's decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        onSample?(sample)
    }

    // MARK: Byte helpers (big endian)

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) << 8 | UInt16(b[o + 1])
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(u32(b, o)) << 32 | UInt64(u32(b, o + 4))
    }

    private static func fourcc(_ b: [UInt8], _ o: Int) -> String {
        String(bytes: b[o..<(o + 4)], encoding: .ascii) ?? "????"
    }
}
