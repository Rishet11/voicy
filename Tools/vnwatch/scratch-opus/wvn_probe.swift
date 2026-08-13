// wvn_probe.swift — standalone AVFoundation decode probe for real WhatsApp
// .opus voice notes (W-VOICENOTES task).
//
// Compile (no Package.swift, no repo build):
//   swiftc -o /tmp/wvn_probe/probe wvn_probe.swift
// Run:
//   /tmp/wvn_probe/probe /tmp/wvn_probe/a.opus
//
// Attempts, in the order required by the task:
//   A) AVAudioFile(forReading:) then read into AVAudioPCMBuffer
//   B) AVAsset / AVURLAsset with AVAssetReader
//   C) AVAudioConverter from a compressed input format
//
// Prints real decoded stats only; never prints audio content or transcripts.
import AVFoundation
import AudioToolbox
import Foundation

func describe(_ e: Error) -> String {
    let n = e as NSError
    return "\(e) | NSError domain=\(n.domain) code=\(n.code) desc=\(n.localizedDescription)"
}

func stats(_ buf: AVAudioPCMBuffer, _ label: String) {
    let n = Int(buf.frameLength)
    guard let ch = buf.floatChannelData?[0], n > 0 else {
        print("\(label): frameLength=\(n), no float channel data")
        return
    }
    var peak: Float = 0
    var nonSilent = 0
    for i in 0..<n {
        let v = abs(ch[i])
        if v > peak { peak = v }
        if v > 0.001 { nonSilent += 1 }
    }
    print("\(label): frames=\(n) peak=\(peak) nonSilent=\(nonSilent)/\(n)")
}

func attemptA(_ url: URL) {
    print("=== A: AVAudioFile(forReading:) ===")
    do {
        let f = try AVAudioFile(forReading: url)
        print("A OK: fileFormat=\(f.fileFormat)")
        print("A OK: processingFormat=\(f.processingFormat)")
        let secs = f.processingFormat.sampleRate > 0
            ? Double(f.length) / f.processingFormat.sampleRate : 0
        print("A OK: length=\(f.length) frames (\(secs) s)")
        let capped = min(Int64(f.length), Int64(f.processingFormat.sampleRate * 60))
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: f.processingFormat,
            frameCapacity: AVAudioFrameCount(capped)) else {
            print("A FAIL: PCM buffer alloc failed")
            return
        }
        try f.read(into: buf)
        stats(buf, "A PCM")
    } catch {
        print("A FAIL: \(describe(error))")
    }
}

func attemptB(_ url: URL) {
    print("=== B: AVURLAsset + AVAssetReader ===")
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            print("B: isPlayable=\(playable)")
            print("B: audio track count=\(tracks.count)")
            guard let track = tracks.first else {
                print("B FAIL: no audio track in asset")
                sem.signal()
                return
            }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else {
            print("B FAIL: reader cannot add output")
            return
        }
        reader.add(output)
        guard reader.startReading() else {
            print("B FAIL: startReading()=false error=\(String(describing: reader.error))")
            return
        }
        var totalFrames = 0
        var bufferCount = 0
        while let sb = output.copyNextSampleBuffer() {
            totalFrames += CMSampleBufferGetNumSamples(sb)
            bufferCount += 1
        }
        print("B RESULT: buffers=\(bufferCount) frames=\(totalFrames) status=\(reader.status.rawValue) error=\(String(describing: reader.error))")
        } catch {
            print("B FAIL: \(describe(error))")
        }
        sem.signal()
    }
    sem.wait()
}
func attemptC(_ url: URL) {
    print("=== C: AVAudioConverter from compressed input format ===")
    // Get raw compressed opus packets with the AudioToolbox AudioFile API,
    // then hand them to an AVAudioConverter (the AVFoundation decode path).
    var fid: AudioFileID?
    let open = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fid)
    guard open == noErr, let id = fid else {
        print("C FAIL: AudioFileOpenURL status=\(open)")
        return
    }
    defer { AudioFileClose(id) }

    var asbd = AudioStreamBasicDescription()
    var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let fmtStatus = AudioFileGetProperty(id, kAudioFilePropertyDataFormat, &sz, &asbd)
    print("C: kAudioFilePropertyDataFormat status=\(fmtStatus)")
    guard fmtStatus == noErr, let comp = AVAudioFormat(streamDescription: &asbd) else {
        print("C FAIL: no AVAudioFormat from ASBD (status=\(fmtStatus))")
        return
    }
    print("C: compressed format=\(comp)")

    var nPackets64: UInt64 = 0
    sz = UInt32(MemoryLayout<UInt64>.size)
    let pcStatus = AudioFileGetProperty(id, kAudioFilePropertyAudioDataPacketCount, &sz, &nPackets64)
    print("C: packet count status=\(pcStatus) nPackets=\(nPackets64)")
    guard pcStatus == noErr, nPackets64 > 0, nPackets64 <= 1_000_000 else {
        print("C FAIL: packet count unusable")
        return
    }
    let nPackets = Int(nPackets64)

    var ptiSize: UInt32 = 0
    let infoStatus = AudioFileGetPropertyInfo(id, kAudioFilePropertyPacketTableInfo, &ptiSize, nil)
    print("C: packet table info status=\(infoStatus) size=\(ptiSize)")
    guard infoStatus == noErr else {
        print("C FAIL: kAudioFilePropertyPacketTableInfo unsupported, status=\(infoStatus)")
        return
    }
    let pti = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: nPackets)
    defer { pti.deallocate() }
    let ptStatus = AudioFileGetProperty(id, kAudioFilePropertyPacketTableInfo, &ptiSize, pti)
    guard ptStatus == noErr else {
        print("C FAIL: packet table get status=\(ptStatus)")
        return
    }
    var totalBytes = 0
    for i in 0..<nPackets { totalBytes += Int(pti[i].mDataByteSize) }
    print("C: total compressed bytes=\(totalBytes)")

    let dataPtr = UnsafeMutableRawPointer.allocate(byteCount: max(totalBytes, 1), alignment: 1)
    defer { dataPtr.deallocate() }
    var numBytes: UInt32 = 0
    var nRead = UInt32(nPackets)
    let readStatus = AudioFileReadPacketData(id, false, &numBytes, pti, 0, &nRead, dataPtr)
    print("C: AudioFileReadPacketData status=\(readStatus) bytes=\(numBytes) packets=\(nRead)")
    guard readStatus == noErr else {
        print("C FAIL: AudioFileReadPacketData status=\(readStatus)")
        return
    }

    guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: asbd.mSampleRate,
                                  channels: asbd.mChannelsPerFrame,
                                  interleaved: false) else {
        print("C FAIL: could not build output PCM format")
        return
    }
    guard let conv = AVAudioConverter(from: comp, to: pcm) else {
        print("C FAIL: AVAudioConverter(from:to:) returned nil")
        return
    }
    print("C: converter \(conv.inputFormat) -> \(conv.outputFormat)")

    let inBuf = AVAudioCompressedBuffer(format: comp,
                                        packetCapacity: AVAudioPacketCount(nPackets),
                                        maximumPacketSize: 4000)
    inBuf.data.copyMemory(from: dataPtr, byteCount: totalBytes)
    inBuf.byteLength = UInt32(totalBytes)
    inBuf.packetCount = AVAudioPacketCount(nPackets)
    if let descs = inBuf.packetDescriptions {
        for i in 0..<nPackets { descs[i] = pti[i] }
    }

    guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcm,
                                        frameCapacity: AVAudioFrameCount(pcm.sampleRate * 60)) else {
        print("C FAIL: output PCM buffer alloc failed")
        return
    }
    var provided = false
    var convErr: NSError?
    let status = conv.convert(to: outBuf, error: &convErr) { _, statusPtr in
        if !provided {
            provided = true
            statusPtr.pointee = .haveData
            return inBuf
        }
        statusPtr.pointee = .endOfStream
        return nil
    }
    print("C RESULT: convert status=\(status.rawValue) error=\(String(describing: convErr))")
    stats(outBuf, "C PCM")
}

func attemptC2(_ url: URL) {
    print("=== C2: AVAudioConverter, packets via ExtAudioFile client format ===")
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
    print("C2: file data format status=\(fmtStatus)")
    guard fmtStatus == noErr, let comp = AVAudioFormat(streamDescription: &asbd) else {
        print("C2 FAIL: no compressed AVAudioFormat from ASBD (status=\(fmtStatus))")
        return
    }
    print("C2: compressed format=\(comp)")

    // Packet count from the AudioFile API (proven working in attempt C).
    var fid: AudioFileID?
    let ao = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fid)
    guard ao == noErr, let fid2 = fid else {
        print("C2 FAIL: AudioFileOpenURL status=\(ao)")
        return
    }
    var nPackets64: UInt64 = 0
    sz = UInt32(MemoryLayout<UInt64>.size)
    let pc = AudioFileGetProperty(fid2, kAudioFilePropertyAudioDataPacketCount, &sz, &nPackets64)
    AudioFileClose(fid2)
    print("C2: packet count status=\(pc) nPackets=\(nPackets64)")
    guard pc == noErr, nPackets64 > 0, nPackets64 <= 1_000_000 else {
        print("C2 FAIL: packet count unusable")
        return
    }
    let nPackets = Int(nPackets64)

    // Ask ExtAudioFile to hand back raw compressed packets.
    var clientASBD = asbd
    let setStatus = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD)
    print("C2: set client format to compressed status=\(setStatus)")
    guard setStatus == noErr else {
        print("C2 FAIL: cannot set compressed client format, status=\(setStatus)")
        return
    }

    var bytes = [UInt8]()
    var descs = [AudioStreamPacketDescription]()
    let bufCapacity: UInt32 = 4096
    for i in 0..<nPackets {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bufCapacity))
        data.initialize(repeating: 0, count: Int(bufCapacity))
        let ab = AudioBuffer(mNumberChannels: 1, mDataByteSize: bufCapacity, mData: data)
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: ab)
        var nFrames: UInt32 = 1
        let st = ExtAudioFileRead(ref, &nFrames, &abl)
        if st != noErr || nFrames != 1 {
            print("C2 FAIL: read packet \(i) status=\(st) frames=\(nFrames)")
            data.deallocate()
            return
        }
        let byteSize = Int(abl.mBuffers.mDataByteSize)
        bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: byteSize))
        descs.append(AudioStreamPacketDescription(mStartOffset: Int64(bytes.count - byteSize),
                                                  mVariableFramesInPacket: 0,
                                                  mDataByteSize: UInt32(byteSize)))
        data.deallocate()
    }
    print("C2: read \(nPackets) packets, totalBytes=\(bytes.count)")
    guard bytes.count > 0 else {
        print("C2 FAIL: zero compressed bytes read")
        return
    }

    guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: asbd.mSampleRate,
                                  channels: asbd.mChannelsPerFrame,
                                  interleaved: false) else {
        print("C2 FAIL: no PCM output format")
        return
    }
    guard let conv = AVAudioConverter(from: comp, to: pcm) else {
        print("C2 FAIL: AVAudioConverter(from:to:) returned nil for \(comp) -> \(pcm)")
        return
    }
    print("C2: converter \(conv.inputFormat) -> \(conv.outputFormat)")

    let inBuf = AVAudioCompressedBuffer(format: comp,
                                        packetCapacity: AVAudioPacketCount(nPackets),
                                        maximumPacketSize: Int(bufCapacity))
    bytes.withUnsafeBytes { raw in
        inBuf.data.copyMemory(from: raw.baseAddress!, byteCount: bytes.count)
    }
    inBuf.byteLength = UInt32(bytes.count)
    inBuf.packetCount = AVAudioPacketCount(nPackets)
    if let d = inBuf.packetDescriptions {
        for i in 0..<nPackets { d[i] = descs[i] }
    }

    guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcm,
                                        frameCapacity: AVAudioFrameCount(pcm.sampleRate * 60)) else {
        print("C2 FAIL: output PCM buffer alloc failed")
        return
    }
    var provided = false
    var convErr: NSError?
    let status = conv.convert(to: outBuf, error: &convErr) { _, st in
        if !provided {
            provided = true
            st.pointee = .haveData
            return inBuf
        }
        st.pointee = .endOfStream
        return nil
    }
    print("C2 RESULT: convert status=\(status.rawValue) error=\(String(describing: convErr))")
    stats(outBuf, "C2 PCM")
}

func attemptC3(_ url: URL) {
    print("=== C3: ExtAudioFile opus -> PCM client format (AudioToolbox decode) ===")
    var extRef: ExtAudioFileRef?
    let openStatus = ExtAudioFileOpenURL(url as CFURL, &extRef)
    guard openStatus == noErr, let ref = extRef else {
        print("C3 FAIL: ExtAudioFileOpenURL status=\(openStatus)")
        return
    }
    defer { ExtAudioFileDispose(ref) }

    var fileASBD = AudioStreamBasicDescription()
    var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let fStatus = ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileDataFormat, &sz, &fileASBD)
    print("C3: file data format status=\(fStatus) rate=\(fileASBD.mSampleRate) ch=\(fileASBD.mChannelsPerFrame)")

    var clientASBD = AudioStreamBasicDescription(
        mSampleRate: 48000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0)
    let setStatus = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD)
    print("C3: set client format to Float32@48k status=\(setStatus)")
    guard setStatus == noErr else {
        print("C3 FAIL: cannot set PCM client format, status=\(setStatus)")
        return
    }

    var totalFrames = 0
    var maxAbs: Float = 0
    let framesPerRead: UInt32 = 4800
    while true {
        let data = UnsafeMutablePointer<Float>.allocate(capacity: Int(framesPerRead))
        let ab = AudioBuffer(mNumberChannels: 1, mDataByteSize: framesPerRead * 4, mData: data)
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: ab)
        var nFrames: UInt32 = framesPerRead
        let st = ExtAudioFileRead(ref, &nFrames, &abl)
        if st != noErr {
            print("C3: ExtAudioFileRead status=\(st) after totalFrames=\(totalFrames)")
            data.deallocate()
            break
        }
        totalFrames += Int(nFrames)
        for i in 0..<Int(nFrames) {
            let v = abs(data[i])
            if v > maxAbs { maxAbs = v }
        }
        data.deallocate()
        if nFrames < framesPerRead { break }
    }
    print("C3 RESULT: decoded totalFrames=\(totalFrames) maxAbs=\(maxAbs)")
}

if CommandLine.arguments.count < 2 {
    print("usage: probe <file.opus>")
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
print("FILE: \(url.path)")
attemptA(url)
attemptB(url)
attemptC(url)
attemptC2(url)
attemptC3(url)