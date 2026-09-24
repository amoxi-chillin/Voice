import Accelerate
import AudioToolbox

/// Converts interleaved Float32 capture buffers to mono Int16 PCM at the output rate as one continuous stream.
///
/// The sample-rate converter keeps its filter history between calls, so buffer boundaries add no gaps or
/// phase jumps: any split of the input into buffers yields the same output as converting it in one pass.
/// Its low-pass filter removes content above the output Nyquist frequency before decimating.
///
/// Buffers are allocated up front and the converter pulls input through a C callback, so `process` and
/// `flush` don't allocate. Not thread-safe; use each instance from one queue at a time.
final class StreamingPCM16Converter {
    struct SetupError: Error {
        let status: OSStatus
    }

    private struct PendingInput {
        var samples: UnsafePointer<Float32>?
        var frameCount: UInt32 = 0
        var isEndOfStream = false
    }

    /// Returned by the input callback when the current buffer is used up, so the converter keeps its
    /// state and waits for the next buffer instead of treating it as end of stream.
    private static let needsMoreInput: OSStatus = 0x6D6F_7265  // 'more'

    private static let provideInput: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, inUserData in
        let pending = inUserData!.assumingMemoryBound(to: PendingInput.self)

        guard pending.pointee.frameCount > 0, let samples = pending.pointee.samples else {
            ioNumberDataPackets.pointee = 0
            ioData.pointee.mBuffers.mData = nil
            ioData.pointee.mBuffers.mDataByteSize = 0
            return pending.pointee.isEndOfStream ? noErr : StreamingPCM16Converter.needsMoreInput
        }

        let frameCount = min(ioNumberDataPackets.pointee, pending.pointee.frameCount)
        ioData.pointee.mBuffers.mNumberChannels = 1
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: samples)
        ioData.pointee.mBuffers.mDataByteSize = frameCount * UInt32(MemoryLayout<Float32>.size)
        ioNumberDataPackets.pointee = frameCount

        pending.pointee.samples = samples + Int(frameCount)
        pending.pointee.frameCount -= frameCount
        return noErr
    }

    let inputSampleRate: Double
    let outputSampleRate: Double
    let maxInputFrames: Int

    private let converter: AudioConverterRef
    private let pendingInput: UnsafeMutablePointer<PendingInput>
    private let monoBuffer: UnsafeMutablePointer<Float32>
    private let outputBuffer: UnsafeMutablePointer<Int16>
    private let outputCapacity: Int

    init(inputSampleRate: Double, outputSampleRate: Double, maxInputFrames: Int) throws {
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: inputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Int16>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var newConverter: AudioConverterRef?
        var status = AudioConverterNew(&inputFormat, &outputFormat, &newConverter)
        guard status == noErr, let newConverter else {
            throw SetupError(status: status)
        }

        if inputSampleRate != outputSampleRate {
            // The default complexity leaves content just above 8 kHz only ~12 dB down. Mastering at High
            // quality is flat to 7.5 kHz (-1.3 dB at 7.8 kHz) and rejects 8.2 kHz and up by more than 90 dB.
            var complexity = kAudioConverterSampleRateConverterComplexity_Mastering
            status = AudioConverterSetProperty(
                newConverter,
                kAudioConverterSampleRateConverterComplexity,
                UInt32(MemoryLayout<UInt32>.size),
                &complexity
            )
            if status == noErr {
                var quality = kAudioConverterQuality_High
                status = AudioConverterSetProperty(
                    newConverter,
                    kAudioConverterSampleRateConverterQuality,
                    UInt32(MemoryLayout<UInt32>.size),
                    &quality
                )
            }
            guard status == noErr else {
                AudioConverterDispose(newConverter)
                throw SetupError(status: status)
            }
        }

        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.maxInputFrames = maxInputFrames
        converter = newConverter

        pendingInput = UnsafeMutablePointer<PendingInput>.allocate(capacity: 1)
        pendingInput.initialize(to: PendingInput())
        monoBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: maxInputFrames)

        // One buffer's worth of output plus headroom for frames the filter releases in bursts.
        outputCapacity = Int((Double(maxInputFrames) * outputSampleRate / inputSampleRate).rounded(.up)) + 512
        outputBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: outputCapacity)
    }

    deinit {
        AudioConverterDispose(converter)
        pendingInput.deallocate()
        monoBuffer.deallocate()
        outputBuffer.deallocate()
    }

    /// Converts one capture buffer and passes the samples ready so far to `emit`, normally in a single call.
    /// The filter holds back a few milliseconds of output until later input or `flush` arrives.
    func process(
        _ samples: UnsafePointer<Float32>,
        frameCount: Int,
        channelCount: Int,
        emit: (UnsafeBufferPointer<Int16>) -> Void
    ) -> OSStatus {
        guard frameCount > 0, channelCount > 0 else { return noErr }
        guard frameCount <= maxInputFrames else { return kAudio_ParamError }

        let monoSamples: UnsafePointer<Float32>
        if channelCount == 1 {
            monoSamples = samples
        } else {
            // Average the interleaved channels into the mono scratch buffer.
            var scale = 1 / Float32(channelCount)
            let stride = vDSP_Stride(channelCount)
            let length = vDSP_Length(frameCount)
            vDSP_vsmul(samples, stride, &scale, monoBuffer, 1, length)
            for channel in 1..<channelCount {
                vDSP_vsma(samples + channel, stride, &scale, monoBuffer, 1, monoBuffer, 1, length)
            }
            monoSamples = UnsafePointer(monoBuffer)
        }

        pendingInput.pointee = PendingInput(samples: monoSamples, frameCount: UInt32(frameCount))
        return convertPendingInput(emit: emit)
    }

    /// Emits the output the filter is still holding, then resets so the next input starts a new stream.
    func flush(emit: (UnsafeBufferPointer<Int16>) -> Void) -> OSStatus {
        pendingInput.pointee = PendingInput(isEndOfStream: true)
        let status = convertPendingInput(emit: emit)
        reset()
        return status
    }

    /// Discards held output and filter history.
    func reset() {
        AudioConverterReset(converter)
        pendingInput.pointee = PendingInput()
    }

    private func convertPendingInput(emit: (UnsafeBufferPointer<Int16>) -> Void) -> OSStatus {
        while true {
            var frameCount = UInt32(outputCapacity)
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: frameCount * UInt32(MemoryLayout<Int16>.size),
                    mData: outputBuffer
                )
            )

            let status = AudioConverterFillComplexBuffer(
                converter,
                Self.provideInput,
                pendingInput,
                &frameCount,
                &bufferList,
                nil
            )

            if frameCount > 0 {
                emit(UnsafeBufferPointer(start: outputBuffer, count: Int(frameCount)))
            }

            if status == Self.needsMoreInput {
                return noErr
            }
            if status != noErr {
                return status
            }
            // Mid-stream, noErr means the output buffer filled up, so keep going until the input is used up.
            if pendingInput.pointee.isEndOfStream && Int(frameCount) < outputCapacity {
                return noErr
            }
        }
    }
}
