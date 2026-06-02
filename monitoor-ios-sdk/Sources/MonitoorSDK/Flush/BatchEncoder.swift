import Foundation

struct BatchEncoder {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    func encode(batch: IngestBatch) throws -> Data {
        try encoder.encode(batch)
    }
}
