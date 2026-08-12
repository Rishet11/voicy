// Scratch AVFoundation decode test for WhatsApp .opus voice notes.
// Compiled standalone: swiftc scratch-opus/main.swift -o /tmp/opus_test/avtest
// Attempts: A) AVAudioFile -> AVAudioPCMBuffer
//           B) AVURLAsset + AVAssetReader
//           C) AVAudioConverter from compressed opus format
import AVFoundation
import Foundation

func pcmStats(_ buf: AVAudioPCMBuffer, label: String) {
    guard let ch = buf.floatChannelData?[0] else {
        print("\(label): no float data, frames=\(buf.frameLength)")
        return
    }
    let n = Int(buf.frameLength)
    var maxAbs: Float = 0
    var nonSilent = 0
    for i in 0..<n {
        let v = abs(ch[i])
        if v > maxAbs { maxAbs = v }
        if v > 0.001 { nonSilent += 1 }
    }
    let frac = n > 0 ? Float(nonSilent) / Float(n) : 0
    print("\(label): frames=\(n) maxAbs=\(maxAbs) nonSilentFrames=\(nonSilent) nonSilentFrac=\(frac)")
}

func attemptA(_ url: URL) {
    print("--- A: AVAudioFile(forReading:) ---")
    do {
        let f = try AVAudioFile(forReading: url)
        let dur = f.processingFormat.sampleRate > 0 ? Double(f.length) / f.processingFormat.sampleRate : 0
        print("A OK: fileFormat=\(f.fileFormat)")
        print("A OK: processingFormat=\(f.processingFormat)")
        print("A OK: length=\(f.length) frames, duration=\(dur)s")
        let cap = AVAudioFrameCount(min(Int(f.length), Int(f.processingFormat.sampleRate * 60)))
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: cap) else {
            print("A FAIL: could not allocate PCM buffer")
            return
        }
        try f.read(into: buf)
        pcmStats(buf, label: "A PCM")
    } catch {
        let e = error as NSError
        print("A FAIL: \(error)")
        print("A FAIL NSError: domain=\(e.domain) code=\(e.code) desc=\(e.localizedDescription)")
    }
}

func attemptB(_ url: URL) {
    print("--- B: AVURLAsset + AVAssetReader ---")
    do {
        let asset = AVURLAsset(url: url)
        print("B: isPlayable=\(asset.isPlayable)")
        let tracks = asset.tracks(withMediaType: .audio)
        print("B: audio track count=\(tracks.count)")
        guard let track = tracks.first else {
            print("B FAIL: no audio track")
            return
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else {
            print("B FAIL: cannot add output")
            return
        }
        reader.add(output)
        guard reader.startReading() else {
            print("B FAIL: startReading false, error=\(String(describing: reader.error))")
            return
        }
        var totalFrames = 0
        var bufferCount = 0
        while let sb = output.copyNextSampleBuffer() {
            totalFrames += CMSampleBufferGetNumSamples(sb)
            bufferCount += 1
        }
        print("B OK: buffers=\(bufferCount) totalFrames=\(totalFrames) status=\(reader.status.rawValue) error=\(String(describing: reader.error))")
    } catch {
        let e = error as NSError
        print("B FAIL: \(error)")
        print("B FAIL NSError: domain=\(e.domain) code=\(e.code) desc=\(e.localizedDescription)")
    }
}

func attemptC(_ url: URL) {
    print("--- C: AVAudioConverter from compressed input format ---")
    // Source compressed opus packets via AudioToolbox AudioFile API,
    // then decode with AVAudioConverter (the AVFoundation piece under test).
    var fileID: AudioFileID?
    let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
    guard openStatus == noErr, let fid = fileID else {
        print("C FAIL: AudioFileOpenURL status=\(openStatus)")
        return
    }
    defer { AudioFileClose(fid) }

    var asbd = AudioStreamBasicDescription()
    var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let fmtStatus = AudioFileGetProperty(fid, kAudioFilePropertyDataFormat, &sz, &asbd)
    print("C: AudioFile data format status=\(fmtStatus) asbd=\(asbd)")
    guard fmtStatus == noErr, let compFmt = AVAudioFormat(streamDescription: &asbd) else {
        print("C FAIL: could not get compressed AVAudioFormat")
        return
    }

    var nPackets64: UInt64 = 0
    sz = UInt32(MemoryLayout<UInt64>.size)
    let pcStatus = AudioFileGetProperty(fid, kAudioFilePropertyAudioDataPacketCount, &sz, &nPackets64)
    let nPackets = Int(nPackets64)
    print("C: packet count status=\(pcStatus) nPackets=\(nPackets)")
    guard pcStatus == noErr, nPackets > 0 else {
        print("C FAIL: no packets")
        return
    }

    // Packet table for variable-size opus packets.
    var ptiSize: UInt32 = 0
    let ptiInfoStatus = AudioFileGetPropertyInfo(fid, kAudioFilePropertyPacketTableInfo, &ptiSize, nil)
    print("C: packet table info status=\(ptiInfoStatus) size=\(ptiSize)")
    guard ptiInfoStatus == noErr else {
        print("C FAIL: kAudioFilePropertyPacketTableInfo unsupported, status=\(ptiInfoStatus)")
        return
    }
    let pti = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: nPackets)
    defer { pti.deallocate() }
    let ptiStatus = AudioFileGetProperty(fid, kAudioFilePropertyPacketTableInfo, &ptiSize, pti)
    print("C: packet table get status=\(ptiStatus)")
    guard ptiStatus == noErr else {
        print("C FAIL: could not get packet table, status=\(ptiStatus)")
        return
    }
    var totalBytes = 0
    for i in 0..<nPackets { totalBytes += Int(pti[i].mDataByteSize) }
    print("C: total compressed bytes=\(totalBytes)")

    let dataPtr = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 1)
    defer { dataPtr.deallocate() }
    var numBytes: UInt32 = 0
    var numPacketsRead = UInt32(nPackets)
    let readStatus = AudioFileReadPacketData(fid, false, &numBytes, pti, 0, &numPacketsRead, dataPtr)
    print("C: AudioFileReadPacketData status=\(readStatus) bytes=\(numBytes) packets=\(numPacketsRead)")
    guard readStatus == noErr else {
        print("C FAIL: AudioFileReadPacketData failed, status=\(readStatus)")
        return
    }

    let pcmFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: asbd.mSampleRate,
                               channels: asbd.mChannelsPerFrame,
                               interleaved: false)!
    guard let conv = AVAudioConverter(from: compFmt, to: pcmFmt) else {
        print("C FAIL: AVAudioConverter init returned nil for \(compFmt) -> \(pcmFmt)")
        return
    }
    print("C OK: converter created: \(conv.inputFormat) -> \(conv.outputFormat)")

    let compBuf = AVAudioCompressedBuffer(format: compFmt,
                                          packetCapacity: AVAudioPacketCount(nPackets),
                                          maximumPacketSize: 4000)
    compBuf.data.copyMemory(from: dataPtr, byteCount: totalBytes)
    compBuf.byteLength = UInt32(totalBytes)
    compBuf.packetCount = AVAudioPacketCount(nPackets)
    if let descs = compBuf.packetDescriptions {
        for i in 0..<nPackets { descs[i] = pti[i] }
    }

    let outCap = AVAudioFrameCount(pcmFmt.sampleRate * 60)
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: outCap) else {
        print("C FAIL: could not allocate output buffer")
        return
    }
    var provided = false
    var err: NSError?
    let status = conv.convert(to: outBuf, error: &err) { _, statusPtr in
        if !provided {
            provided = true
            statusPtr.pointee = .haveData
            return compBuf
        }
        statusPtr.pointee = .endOfStream
        return nil
    }
    print("C: convert status=\(status.rawValue) err=\(String(describing: err))")
    pcmStats(outBuf, label: "C PCM")
}

// C2: like C, but source compressed packets via ExtAudioFile with the client
// data format set to the compressed format (Ogg packet table was unusable).
func attemptC2(_ url: URL) {
    print("--- C2: AVAudioConverter, packets sourced via ExtAudioFile client format ---")
    var extRef: ExtAudioFileRef?
    let openStatus = ExtAudioFileOpenURL(url as CFURL, &extRef)
    guard openStatus == noErr, let ref = extRef else {
        print("C2 FAIL: ExtAudioFileOpenURL status=\(openStatus)")
        return
    }
    defer { ExtAudioFileDispose(ref) }

    var asbd = AudioStreamBasicDescription()
    var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let fmtStatus = ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileDataFormat, &sz, &asbd)
    print("C2: file data format status=\(fmtStatus) asbd=\(asbd)")
    guard fmtStatus == noErr, let compFmt = AVAudioFormat(streamDescription: &asbd) else {
        print("C2 FAIL: no compressed format")
        return
    }
    // Ask ExtAudioFile for raw compressed packets.
    var clientASBD = asbd
    let setStatus = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD)
    print("C2: set client format to compressed, status=\(setStatus)")
    guard setStatus == noErr else {
        print("C2 FAIL: cannot set compressed client format, status=\(setStatus)")
        return
    }
    var fileFrames: Int64 = 0
    sz = UInt32(MemoryLayout<Int64>.size)
    let lenStatus = ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileLengthFrames, &sz, &fileFrames)
    print("C2: file length frames status=\(lenStatus) frames=\(fileFrames)")
    let nPackets = Int(fileFrames)

    // Read one packet at a time to learn VBR packet boundaries.
    var bytes = [UInt8]()
    var descs = [AudioStreamPacketDescription]()
    let bufCapacity: UInt32 = 4096
    for i in 0..<nPackets {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bufCapacity))
        defer { data.deallocate() }
        let ab = AudioBuffer(mNumberChannels: 1,
                             mDataByteSize: bufCapacity,
                             mData: data)
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: ab)
        var nFrames: UInt32 = 1
        let st = ExtAudioFileRead(ref, &nFrames, &abl)
        if st != noErr || nFrames != 1 {
            print("C2 FAIL: read packet \(i) status=\(st) frames=\(nFrames)")
            return
        }
        let byteSize = Int(abl.mBuffers.mDataByteSize)
        let offset = Int64(bytes.count)
        bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: byteSize))
        descs.append(AudioStreamPacketDescription(mStartOffset: offset,
                                                  mVariableFramesInPacket: 0,
                                                  mDataByteSize: UInt32(byteSize)))
    }
    print("C2: read \(nPackets) packets, totalBytes=\(bytes.count)")

    let pcmFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: asbd.mSampleRate,
                               channels: asbd.mChannelsPerFrame,
                               interleaved: false)!
    guard let conv = AVAudioConverter(from: compFmt, to: pcmFmt) else {
        print("C2 FAIL: AVAudioConverter init returned nil for \(compFmt) -> \(pcmFmt)")
        return
    }
    print("C2 OK: converter created: \(conv.inputFormat) -> \(conv.outputFormat)")

    let compBuf = AVAudioCompressedBuffer(format: compFmt,
                                          packetCapacity: AVAudioPacketCount(nPackets),
                                          maximumPacketSize: 4000)
    bytes.withUnsafeBytes { raw in
        compBuf.data.copyMemory(from: raw.baseAddress!, byteCount: bytes.count)
    }
    compBuf.byteLength = UInt32(bytes.count)
    compBuf.packetCount = AVAudioPacketCount(nPackets)
    if let outDescs = compBuf.packetDescriptions {
        for i in 0..<nPackets { outDescs[i] = descs[i] }
    }

    let outCap = AVAudioFrameCount(pcmFmt.sampleRate * 60)
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: outCap) else {
        print("C2 FAIL: could not allocate output buffer")
        return
    }
    var provided = false
    var err: NSError?
    let status = conv.convert(to: outBuf, error: &err) { _, statusPtr in
        if !provided {
            provided = true
            statusPtr.pointee = .haveData
            return compBuf
        }
        statusPtr.pointee = .endOfStream
        return nil
    }
    print("C2: convert status=\(status.rawValue) err=\(String(describing: err))")
    pcmStats(outBuf, label: "C2 PCM")
}


let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/opus_test/b.opus"
let url = URL(fileURLWithPath: path)
print("FILE: \(path)")
attemptA(url)
attemptB(url)
attemptC(url)
attemptC2(url)
