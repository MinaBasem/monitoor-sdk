import Foundation
import Compression

struct BatchEncoder {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    /// Encodes `events` into the wire JSON, then gzip-compresses if the payload exceeds 1 KB.
    /// Returns (data, isCompressed).
    func encode(batch: IngestBatch) throws -> (Data, Bool) {
        let json = try encoder.encode(batch)
        if json.count > 1024, let compressed = gzip(json) {
            return (compressed, true)
        }
        return (json, false)
    }

    // MARK: - gzip via Compression framework (iOS 13+)

    private func gzip(_ data: Data) -> Data? {
        let pageSize = 65536
        var output = Data()

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }

        var status = compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(stream) }

        // Add gzip header manually (zlib produces raw DEFLATE, not gzip).
        output.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])

        var inputBuffer = Array(data)
        stream.pointee.src_ptr  = UnsafePointer(inputBuffer)
        stream.pointee.src_size = inputBuffer.count

        var outputBuffer = [UInt8](repeating: 0, count: pageSize)
        repeat {
            stream.pointee.dst_ptr  = UnsafeMutablePointer(&outputBuffer)
            stream.pointee.dst_size = pageSize

            status = compression_stream_process(
                stream,
                stream.pointee.src_size == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            )
            guard status != COMPRESSION_STATUS_ERROR else { return nil }

            let produced = pageSize - stream.pointee.dst_size
            output.append(contentsOf: outputBuffer.prefix(produced))
        } while status == COMPRESSION_STATUS_OK

        // CRC32 and original size trailer.
        var crc = crc32(data: data)
        var size = UInt32(data.count)
        withUnsafeBytes(of: &crc)  { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }

        return output
    }

    private func crc32(data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xEDB88320)
            }
        }
        return ~crc
    }
}
