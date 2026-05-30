import Foundation

/// Top-level payload sent to POST /v1/ingest.
struct IngestBatch: Encodable {
    let sdkVersion: String
    let batch: [WireEvent]

    enum CodingKeys: String, CodingKey {
        case sdkVersion = "sdk_version"
        case batch
    }
}

/// Response body from POST /v1/ingest.
struct IngestResponse: Decodable {
    let accepted: Int
    let rejected: Int
    let errors: [IngestError]
}

struct IngestError: Decodable {
    let index: Int
    let reason: String
}

/// Thin wrapper tracking which buffer row IDs correspond to which batch positions.
struct OutboundBatch {
    let events: [WireEvent]
    let rowIds: [Int64]

    var count: Int { events.count }

    func rowIdsExcluding(indexes: [Int]) -> [Int64] {
        let rejected = Set(indexes)
        return rowIds.enumerated().compactMap { rejected.contains($0.offset) ? nil : $0.element }
    }

    func rowIdsAt(indexes: [Int]) -> [Int64] {
        indexes.compactMap { $0 < rowIds.count ? rowIds[$0] : nil }
    }
}
