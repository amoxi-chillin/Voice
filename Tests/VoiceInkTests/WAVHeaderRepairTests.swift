import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import VoiceInk

struct WAVHeaderRepairTests {
    @Test func parsesAudioToolboxHeader() throws {
        let header = try #require(WAVHeaderRepair.parseHeader(WAVFixture.audioToolboxHeader()))

        #expect(header.riffSize == 4088)
        #expect(header.dataSize == 0)
        #expect(header.dataSizeOffset == 4092)
        #expect(header.dataOffset == 4096)
        #expect(header.blockAlign == 2)
        #expect(header.byteRate == 32_000)
    }

    @Test func rejectsNonWAVData() {
        #expect(WAVHeaderRepair.parseHeader(Data("not a wav file".utf8)) == nil)
        #expect(WAVHeaderRepair.parseHeader(Data()) == nil)
    }

    @Test func computesSizesFromFileLength() throws {
        let header = try #require(WAVHeaderRepair.parseHeader(WAVFixture.audioToolboxHeader()))

        let repair = WAVHeaderRepair.repair(for: header, fileLength: 4096 + 96_000)

        #expect(repair == WAVHeaderRepair.Repair(riffSize: 4088 + 96_000, dataSize: 96_000, fileLength: 4096 + 96_000))
    }

    @Test func leavesConsistentHeaderAlone() throws {
        let data = WAVFixture.audioToolboxHeader(riffSize: 4088 + 32_000, dataSize: 32_000)
        let header = try #require(WAVHeaderRepair.parseHeader(data))

        #expect(WAVHeaderRepair.repair(for: header, fileLength: 4096 + 32_000) == nil)
        // An empty recording is complete as written.
        let emptyHeader = try #require(WAVHeaderRepair.parseHeader(WAVFixture.audioToolboxHeader()))
        #expect(WAVHeaderRepair.repair(for: emptyHeader, fileLength: 4096) == nil)
    }

    @Test func dropsTrailingPartialFrame() throws {
        let url = WAVFixture.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try (WAVFixture.audioToolboxHeader() + Data(repeating: 7, count: 101)).write(to: url)

        let outcome = try #require(try WAVHeaderRepair.repairIfNeeded(at: url))

        #expect(outcome.wasRepaired)
        #expect(outcome.audioByteCount == 100)
        let repaired = try #require(WAVHeaderRepair.parseHeader(try Data(contentsOf: url)))
        #expect(repaired.dataSize == 100)
        #expect(repaired.riffSize == 4088 + 100)
        #expect(try Data(contentsOf: url).count == 4096 + 100)
    }

    @Test func repairsUnclosedAudioToolboxRecording() throws {
        let url = WAVFixture.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Leave the file open, as a crash or forced quit would.
        let fileRef = try WAVFixture.writeRecording(to: url, frameCount: 24_000)
        defer { ExtAudioFileDispose(fileRef) }
        #expect(try Data(contentsOf: url).prefix(4096) == WAVFixture.audioToolboxHeader())
        #expect(try AVAudioFile(forReading: url).length == 0)

        let outcome = try #require(try WAVHeaderRepair.repairIfNeeded(at: url))

        #expect(outcome.wasRepaired)
        #expect(outcome.audioByteCount == 48_000)
        #expect(outcome.duration == 1.5)
        #expect(try AVAudioFile(forReading: url).length == 24_000)
    }

    @Test func leavesClosedRecordingUnchanged() throws {
        let url = WAVFixture.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        ExtAudioFileDispose(try WAVFixture.writeRecording(to: url, frameCount: 16_000))
        let original = try Data(contentsOf: url)

        let outcome = try #require(try WAVHeaderRepair.repairIfNeeded(at: url))

        #expect(!outcome.wasRepaired)
        #expect(outcome.audioByteCount == 32_000)
        #expect(outcome.duration == 1.0)
        #expect(try Data(contentsOf: url) == original)
    }
}

enum WAVFixture {
    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    }

    /// Mirrors the 16 kHz mono Int16 header AudioToolbox writes before a recording is closed.
    static func audioToolboxHeader(riffSize: UInt32 = 4088, dataSize: UInt32 = 0) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: riffSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))  // PCM
        data.append(littleEndian: UInt16(1))  // mono
        data.append(littleEndian: UInt32(16_000))
        data.append(littleEndian: UInt32(32_000))
        data.append(littleEndian: UInt16(2))
        data.append(littleEndian: UInt16(16))
        // AudioToolbox pads with a filler chunk so audio starts at byte 4096.
        data.append(contentsOf: Array("FLLR".utf8))
        let fillerSize = 4096 - 8 - (data.count + 4)
        data.append(littleEndian: UInt32(fillerSize))
        data.append(Data(count: fillerSize))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataSize)
        return data
    }

    /// Writes a recording the way CoreAudioRecorder does and returns the still-open file.
    static func writeRecording(to url: URL, frameCount: Int) throws -> ExtAudioFileRef {
        var format = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var fileRef: ExtAudioFileRef?
        try check(
            ExtAudioFileCreateWithURL(
                url as CFURL, kAudioFileWAVEType, &format, nil, AudioFileFlags.eraseFile.rawValue, &fileRef))
        let file = try #require(fileRef)
        try check(
            ExtAudioFileSetProperty(
                file,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &format
            ))

        var samples = (0..<frameCount).map { Int16(truncatingIfNeeded: $0 &* 37) }
        try samples.withUnsafeMutableBytes { buffer in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(buffer.count),
                    mData: buffer.baseAddress
                )
            )
            try check(ExtAudioFileWrite(file, UInt32(frameCount), &bufferList))
        }
        return file
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

extension Data {
    fileprivate mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
