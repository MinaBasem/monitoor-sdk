import Foundation

struct CrashFrame: Codable {
    let index: Int
    let image: String
    let address: String
    let offset: Int
}

struct CrashThread: Codable {
    let index: Int
    let crashed: Bool
    let frames: [CrashFrame]
}

struct CrashReport: Codable {
    let sdkVersion: String
    let type: String
    let idempotencyKey: String
    let exceptionType: String
    let exceptionName: String
    let signal: Int32
    let reason: String
    let appVersion: String
    let build: String
    let osVersion: String
    let device: String
    let sessionId: String
    let deviceId: String
    let occurredAt: String
    let threads: [CrashThread]

    enum CodingKeys: String, CodingKey {
        case sdkVersion      = "sdk_version"
        case type
        case idempotencyKey  = "idempotency_key"
        case exceptionType   = "exception_type"
        case exceptionName   = "exception_name"
        case signal
        case reason
        case appVersion      = "app_version"
        case build
        case osVersion       = "os_version"
        case device
        case sessionId       = "session_id"
        case deviceId        = "device_id"
        case occurredAt      = "occurred_at"
        case threads
    }
}

struct CrashResponse: Decodable {
    let crashId: String
    let symbolicated: Bool

    enum CodingKeys: String, CodingKey {
        case crashId     = "crash_id"
        case symbolicated
    }
}
