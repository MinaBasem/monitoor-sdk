import Foundation

/// A buffered event row read from SQLite, ready to be encoded and sent.
struct BufferedEvent {
    let rowId: Int64
    let payload: Data
    let type: BufferRowType
}

enum BufferRowType: String {
    case event   = "event"
    case crash   = "crash"
    case session = "session"
}

/// The JSON context block attached to every event.
struct EventContext: Encodable {
    let appVersion: String
    let build: String
    let os: String
    let device: String
    let locale: String
    let timezone: String
    let bundleId: String

    enum CodingKeys: String, CodingKey {
        case appVersion  = "app_version"
        case build
        case os
        case device
        case locale
        case timezone
        case bundleId    = "bundle_id"
    }
}

/// A single event in the wire-format batch.
struct WireEvent: Encodable {
    let type: String
    let name: String
    let sessionId: String
    let deviceId: String
    let userIdHash: String?
    let idempotencyKey: String
    let occurredAt: String
    let properties: [String: AnyCodable]?
    let context: EventContext

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case sessionId       = "session_id"
        case deviceId        = "device_id"
        case userIdHash      = "user_id_hash"
        case idempotencyKey  = "idempotency_key"
        case occurredAt      = "occurred_at"
        case properties
        case context
    }
}

/// A pending event stored in the local SQLite buffer.
struct PendingEvent: Codable {
    let type: String
    let name: String
    let sessionId: String
    let deviceId: String
    let userIdHash: String?
    let idempotencyKey: String
    let occurredAt: String
    let properties: [String: AnyCodable]?
    let context: EventContext

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case sessionId       = "session_id"
        case deviceId        = "device_id"
        case userIdHash      = "user_id_hash"
        case idempotencyKey  = "idempotency_key"
        case occurredAt      = "occurred_at"
        case properties
        case context
    }
}

/// Type-erased Codable value for arbitrary event properties.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self)   { value = v; return }
        if let v = try? container.decode(Int.self)    { value = v; return }
        if let v = try? container.decode(Double.self) { value = v; return }
        if let v = try? container.decode(String.self) { value = v; return }
        if let v = try? container.decode([String: AnyCodable].self) { value = v; return }
        if let v = try? container.decode([AnyCodable].self) { value = v.map { $0.value }; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool:               try container.encode(v)
        case let v as Int:                try container.encode(v)
        case let v as Double:             try container.encode(v)
        case let v as String:             try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        case let v as [Any]:
            let wrapped = v.map { AnyCodable($0) }
            try container.encode(wrapped)
        default:
            try container.encodeNil()
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func toAnyCodable() -> [String: AnyCodable] {
        mapValues { AnyCodable($0) }
    }
}
