import Foundation

/// Repairs WAV files that were never closed because the app quit, crashed, or the user logged out.
/// AudioToolbox writes the RIFF and data chunk sizes only on close, so an interrupted recording
/// keeps its samples on disk but its header reports no audio.
enum WAVHeaderRepair {
    struct Header: Equatable {
        let riffSize: UInt32
        let dataSize: UInt32
        /// Byte offset of the data chunk's size field.
        let dataSizeOffset: Int
        /// Byte offset of the first audio sample.
        let dataOffset: Int
        let blockAlign: Int
        let byteRate: Int
    }

    struct Repair: Equatable {
        let riffSize: UInt32
        let dataSize: UInt32
        /// File length after dropping a trailing partial frame.
        let fileLength: UInt64
    }

    struct Outcome: Equatable {
        let audioByteCount: UInt64
        let duration: TimeInterval
        let wasRepaired: Bool
    }

    /// AudioToolbox pads its header to 4 KB, so this comfortably reaches the data chunk.
    static let headerReadLength = 64 * 1024

    static func parseHeader(_ data: Data) -> Header? {
        guard data.count >= 12,
            fourCC(in: data, at: 0) == "RIFF",
            fourCC(in: data, at: 8) == "WAVE"
        else {
            return nil
        }

        var byteRate = 0
        var blockAlign = 0
        var offset = 12

        while offset + 8 <= data.count {
            let chunkID = fourCC(in: data, at: offset)
            let chunkSize = uint32(in: data, at: offset + 4)

            if chunkID == "data" {
                guard byteRate > 0, blockAlign > 0 else { return nil }
                return Header(
                    riffSize: uint32(in: data, at: 4),
                    dataSize: chunkSize,
                    dataSizeOffset: offset + 4,
                    dataOffset: offset + 8,
                    blockAlign: blockAlign,
                    byteRate: byteRate
                )
            }

            if chunkID == "fmt " {
                guard chunkSize >= 16, offset + 24 <= data.count else { return nil }
                byteRate = Int(uint32(in: data, at: offset + 16))
                blockAlign = Int(uint16(in: data, at: offset + 20))
            }

            // Chunks are padded to an even length.
            offset += 8 + Int(chunkSize) + Int(chunkSize & 1)
        }

        return nil
    }

    /// Returns the sizes the header should declare, or nil when it already matches the file.
    static func repair(for header: Header, fileLength: UInt64) -> Repair? {
        let dataOffset = UInt64(header.dataOffset)
        guard fileLength >= dataOffset else { return nil }

        let availableBytes = fileLength - dataOffset
        if UInt64(header.riffSize) + 8 == fileLength, UInt64(header.dataSize) <= availableBytes {
            return nil
        }

        let maxDataSize = UInt64(UInt32.max) - (dataOffset - 8)
        let usableBytes = min(availableBytes, maxDataSize)
        let dataSize = usableBytes - usableBytes % UInt64(header.blockAlign)

        return Repair(
            riffSize: UInt32(dataOffset - 8 + dataSize),
            dataSize: UInt32(dataSize),
            // Never truncate audio beyond the 4 GB WAV limit; only a partial frame is dropped.
            fileLength: availableBytes > maxDataSize ? fileLength : dataOffset + dataSize
        )
    }

    /// Fixes the header in place when needed. Returns nil for files that are not WAV audio.
    static func repairIfNeeded(at url: URL) throws -> Outcome? {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let fileLength = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let headerData = try handle.read(upToCount: headerReadLength),
            let header = parseHeader(headerData)
        else {
            return nil
        }

        guard let repair = Self.repair(for: header, fileLength: fileLength) else {
            let audioByteCount = min(UInt64(header.dataSize), fileLength - UInt64(header.dataOffset))
            return Outcome(
                audioByteCount: audioByteCount,
                duration: duration(ofAudioBytes: audioByteCount, header: header),
                wasRepaired: false
            )
        }

        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndianData(repair.riffSize))
        try handle.seek(toOffset: UInt64(header.dataSizeOffset))
        try handle.write(contentsOf: littleEndianData(repair.dataSize))
        if repair.fileLength < fileLength {
            try handle.truncate(atOffset: repair.fileLength)
        }
        try handle.synchronize()

        let audioByteCount = UInt64(repair.dataSize)
        return Outcome(
            audioByteCount: audioByteCount,
            duration: duration(ofAudioBytes: audioByteCount, header: header),
            wasRepaired: true
        )
    }

    private static func duration(ofAudioBytes byteCount: UInt64, header: Header) -> TimeInterval {
        TimeInterval(byteCount) / TimeInterval(header.byteRate)
    }

    private static func fourCC(in data: Data, at offset: Int) -> String {
        let start = data.startIndex + offset
        return String(decoding: data[start..<start + 4], as: UTF8.self)
    }

    private static func uint16(in data: Data, at offset: Int) -> UInt16 {
        let start = data.startIndex + offset
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return (0..<4).reduce(UInt32(0)) { value, index in
            value | UInt32(data[start + index]) << (8 * UInt32(index))
        }
    }

    private static func littleEndianData(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
