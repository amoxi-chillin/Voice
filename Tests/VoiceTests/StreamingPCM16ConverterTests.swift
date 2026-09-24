import AudioToolbox
import Foundation
import Testing
@testable import Voice

struct StreamingPCM16ConverterTests {
    private static let outputRate = 16_000.0
    private static let amplitude: Float32 = 0.5

    // MARK: - Output length

    @Test func outputLengthMatchesInputDurationForTypical48kHzBuffers() throws {
        // 10 s at 48 kHz in 512-frame buffers. Per-buffer truncation used to lose ~39 ms here.
        let input = sine(frequency: 1_000, sampleRate: 48_000, frameCount: 480_000)
        let output = try convert(input, sampleRate: 48_000, bufferFrames: [512])
        #expect(output.count == 160_000)
    }

    @Test(arguments: [
        (44_100.0, 441), (44_100, 512), (48_000, 480), (96_000, 1_024), (24_000, 256), (16_000, 512),
    ])
    func outputLengthMatchesInputDuration(sampleRate: Double, bufferFrames: Int) throws {
        let input = sine(frequency: 1_000, sampleRate: sampleRate, frameCount: Int(sampleRate * 3))
        let output = try convert(input, sampleRate: sampleRate, bufferFrames: [bufferFrames])
        #expect(output.count == 48_000)
    }

    // MARK: - Continuity across buffers

    @Test func bufferBoundariesDoNotChangeOutput() throws {
        let input = chirp(from: 50, to: 20_000, sampleRate: 48_000, frameCount: 96_000)
        let singlePass = try convert(input, sampleRate: 48_000, bufferFrames: [input.count])

        for bufferFrames in [[512], [480], [4_096], [512, 511, 37, 1_024, 1, 300]] {
            let buffered = try convert(input, sampleRate: 48_000, bufferFrames: bufferFrames)
            #expect(buffered == singlePass, "buffer sizes \(bufferFrames)")
        }
    }

    @Test func sineStaysContinuousAcross48kHzBuffers() throws {
        let frequency = 1_000.0
        let input = sine(frequency: frequency, sampleRate: 48_000, frameCount: 144_000)
        let output = try convert(input, sampleRate: 48_000, bufferFrames: [512])

        // Skip the filter's start and end transients; 46,400 samples is a whole number of 1 kHz periods.
        let steadyState = Array(output[800..<47_200]).map(Double.init)
        let fit = fitSinusoid(steadyState, frequency: frequency, sampleRate: Self.outputRate)
        let expectedAmplitude = Double(Self.amplitude) * 32_767

        // A dropped or repeated input sample at a buffer boundary shows up as a phase jump that a single
        // sinusoid can't fit; length drift shows up as a frequency error that it can't fit either.
        #expect(abs(fit.amplitude - expectedAmplitude) < 4)
        #expect(fit.maxResidual < 2)

        // No step between neighboring samples is larger than the sine itself can produce.
        let largestStep = zip(steadyState, steadyState.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        let largestSineStep = expectedAmplitude * 2 * sin(.pi * frequency / Self.outputRate)
        #expect(largestStep <= largestSineStep + 16)
    }

    // MARK: - Band limiting

    @Test(arguments: [9_000.0, 12_000, 20_000])
    func removesContentAboveOutputNyquist(frequency: Double) throws {
        // Without a low-pass filter these tones alias into the speech band at close to full level.
        let input = sine(frequency: frequency, sampleRate: 48_000, frameCount: 48_000)
        let output = try convert(input, sampleRate: 48_000, bufferFrames: [512])

        let steadyState = output[800..<(output.count - 800)]
        let peak = steadyState.map { abs(Int($0)) }.max() ?? 0
        #expect(peak <= 2)
    }

    @Test(arguments: [300.0, 1_000, 3_400, 7_000])
    func passesSpeechBandAtUnityGain(frequency: Double) throws {
        let input = sine(frequency: frequency, sampleRate: 48_000, frameCount: 144_000)
        let output = try convert(input, sampleRate: 48_000, bufferFrames: [512])

        let steadyState = output[800..<47_200].map(Double.init)
        let rms = sqrt(steadyState.map { $0 * $0 }.reduce(0, +) / Double(steadyState.count))
        let expectedRMS = Double(Self.amplitude) * 32_767 / sqrt(2)
        #expect(abs(20 * log10(rms / expectedRMS)) < 0.1)
    }

    // MARK: - Channels and stream lifecycle

    @Test func averagesInterleavedChannelsToMono() throws {
        let mono = sine(frequency: 1_000, sampleRate: 48_000, frameCount: 48_000)
        let monoOutput = try convert(mono, sampleRate: 48_000, bufferFrames: [512])

        let identical = interleave(mono, mono)
        #expect(try convert(identical, sampleRate: 48_000, channelCount: 2, bufferFrames: [512]) == monoOutput)

        let inverted = interleave(mono, mono.map { -$0 })
        let cancelled = try convert(inverted, sampleRate: 48_000, channelCount: 2, bufferFrames: [512])
        #expect(cancelled.count == monoOutput.count)
        #expect(cancelled.allSatisfy { $0 == 0 })
    }

    @Test func flushStartsANewStream() throws {
        let input = chirp(from: 100, to: 7_000, sampleRate: 48_000, frameCount: 24_000)
        let converter = try StreamingPCM16Converter(
            inputSampleRate: 48_000,
            outputSampleRate: Self.outputRate,
            maxInputFrames: 4_096
        )

        let first = try convert(input, with: converter, channelCount: 1, bufferFrames: [512])
        let second = try convert(input, with: converter, channelCount: 1, bufferFrames: [512])
        #expect(first.count == 8_000)
        #expect(second == first)
    }

    @Test func rejectsBuffersLargerThanItsCapacity() throws {
        let converter = try StreamingPCM16Converter(
            inputSampleRate: 48_000,
            outputSampleRate: Self.outputRate,
            maxInputFrames: 512
        )
        let input = [Float32](repeating: 0, count: 513)
        var emitted = 0
        let status = input.withUnsafeBufferPointer { samples in
            converter.process(samples.baseAddress!, frameCount: samples.count, channelCount: 1) {
                emitted += $0.count
            }
        }
        #expect(status == kAudio_ParamError)
        #expect(emitted == 0)
    }

    // MARK: - Helpers

    private func convert(
        _ input: [Float32],
        sampleRate: Double,
        channelCount: Int = 1,
        bufferFrames: [Int]
    ) throws -> [Int16] {
        let converter = try StreamingPCM16Converter(
            inputSampleRate: sampleRate,
            outputSampleRate: Self.outputRate,
            maxInputFrames: bufferFrames.max()!
        )
        return try convert(input, with: converter, channelCount: channelCount, bufferFrames: bufferFrames)
    }

    /// Feeds `input` through `converter` in buffers cycling through `bufferFrames`, then flushes.
    private func convert(
        _ input: [Float32],
        with converter: StreamingPCM16Converter,
        channelCount: Int,
        bufferFrames: [Int]
    ) throws -> [Int16] {
        var output: [Int16] = []
        let totalFrames = input.count / channelCount

        try input.withUnsafeBufferPointer { samples in
            var frame = 0
            var bufferIndex = 0
            while frame < totalFrames {
                let frameCount = min(bufferFrames[bufferIndex % bufferFrames.count], totalFrames - frame)
                let status = converter.process(
                    samples.baseAddress! + frame * channelCount,
                    frameCount: frameCount,
                    channelCount: channelCount
                ) { output.append(contentsOf: $0) }
                try #require(status == noErr)
                frame += frameCount
                bufferIndex += 1
            }
        }

        let status = converter.flush { output.append(contentsOf: $0) }
        try #require(status == noErr)
        return output
    }

    private func sine(frequency: Double, sampleRate: Double, frameCount: Int) -> [Float32] {
        (0..<frameCount).map { Self.amplitude * Float32(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    private func chirp(from startFrequency: Double, to endFrequency: Double, sampleRate: Double, frameCount: Int)
        -> [Float32]
    {
        let duration = Double(frameCount) / sampleRate
        let sweepRate = (endFrequency - startFrequency) / duration
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            return Self.amplitude * Float32(sin(2 * .pi * (startFrequency * time + sweepRate / 2 * time * time)))
        }
    }

    private func interleave(_ left: [Float32], _ right: [Float32]) -> [Float32] {
        zip(left, right).flatMap { [$0, $1] }
    }

    /// Least-squares fit of a sinusoid at a known frequency. Assumes `samples` spans whole periods.
    private func fitSinusoid(_ samples: [Double], frequency: Double, sampleRate: Double)
        -> (amplitude: Double, maxResidual: Double)
    {
        let omega = 2 * .pi * frequency / sampleRate
        var sineWeight = 0.0
        var cosineWeight = 0.0
        for (index, sample) in samples.enumerated() {
            sineWeight += sample * sin(omega * Double(index))
            cosineWeight += sample * cos(omega * Double(index))
        }
        sineWeight *= 2 / Double(samples.count)
        cosineWeight *= 2 / Double(samples.count)

        var maxResidual = 0.0
        for (index, sample) in samples.enumerated() {
            let fitted = sineWeight * sin(omega * Double(index)) + cosineWeight * cos(omega * Double(index))
            maxResidual = max(maxResidual, abs(sample - fitted))
        }
        return (hypot(sineWeight, cosineWeight), maxResidual)
    }
}
