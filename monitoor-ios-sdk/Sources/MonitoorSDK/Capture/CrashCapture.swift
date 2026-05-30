import Foundation

// MARK: - CrashCapture
// Signal/exception handlers must be async-signal-safe.
// No malloc, no ObjC, no Swift ARC inside the signal handler itself.

final class CrashCapture {

    // Pre-allocated crash report path (set once at install time).
    private static var crashDirectoryPath: String = ""
    private static var deviceId: String = ""
    private static var sessionId: String = ""
    private static var deviceModel: String = ""
    private static var osVersion: String = ""
    private static var appVersion: String = ""
    private static var build: String = ""

    private static var previousHandlers: [Int32: (@convention(c) (Int32) -> Void)?] = [:]
    private static var previousExceptionHandler: NSUncaughtExceptionHandler?

    private let crashDirectory: URL
    private let httpClient: HTTPClient
    private let apiKey: String
    private let ingestURL: URL

    init(crashDirectory: URL, httpClient: HTTPClient, apiKey: String, ingestURL: URL) {
        self.crashDirectory = crashDirectory
        self.httpClient     = httpClient
        self.apiKey         = apiKey
        self.ingestURL      = ingestURL
    }

    func install(deviceInfo: DeviceInfo, deviceId: String, sessionId: String) {
        try? FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)

        CrashCapture.crashDirectoryPath = crashDirectory.path
        CrashCapture.deviceId    = deviceId
        CrashCapture.sessionId   = sessionId
        CrashCapture.deviceModel = deviceInfo.model
        CrashCapture.osVersion   = deviceInfo.osVersion
        CrashCapture.appVersion  = deviceInfo.appVersion
        CrashCapture.build       = deviceInfo.build

        CrashCapture.previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashCapture.handleException(exception)
        }

        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signal in
                CrashCapture.handleSignal(signal)
            }
            sigaction(sig, &action, nil)
        }
    }

    /// Uploads any pending crash files from the previous session. Call this early in configure().
    func uploadPendingCrashes() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: crashDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let report = try? JSONDecoder().decode(CrashReport.self, from: data)
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let fileURL = file
            Task {
                let result = await httpClient.sendCrash(report: report, apiKey: apiKey, ingestURL: ingestURL)
                if case .success = result {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    // MARK: - Signal-safe handlers

    private static func handleSignal(_ signal: Int32) {
        writeCrashFile(signal: signal, exception: nil)
        // Re-raise so the system generates a crash log.
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        sigaction(signal, &action, nil)
        raise(signal)
    }

    private static func handleException(_ exception: NSException) {
        writeCrashFile(signal: 0, exception: exception)
        previousExceptionHandler?(exception)
    }

    private static func writeCrashFile(signal: Int32, exception: NSException?) {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let fileName  = "\(crashDirectoryPath)/crash_\(timestamp).json"

        // Capture stack frames using backtrace() — async-signal-safe.
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let frameCount = backtrace(&frames, 64)

        let exceptionType = exception?.name.rawValue ?? signalName(signal)
        let reason        = exception?.reason ?? signalReason(signal)

        var crashFrames: [[String: String]] = []
        for i in 0..<frameCount {
            guard let ptr = frames[i] else { continue }
            crashFrames.append([
                "index":   "\(i)",
                "address": "0x\(String(UInt(bitPattern: ptr), radix: 16))",
            ])
        }

        // Build a minimal JSON blob without using Foundation's JSONEncoder (not signal-safe).
        var json = "{"
        json += "\"sdk_version\":\"\(MonitoorSDK.version)\","
        json += "\"type\":\"crash\","
        json += "\"idempotency_key\":\"\(deviceId)-crash-\(timestamp)\","
        json += "\"exception_type\":\"\(exceptionType)\","
        json += "\"exception_name\":\"\(exceptionType)\","
        json += "\"signal\":\(signal),"
        json += "\"reason\":\"\(reason.replacingOccurrences(of: "\"", with: "'"))\","
        json += "\"app_version\":\"\(appVersion)\","
        json += "\"build\":\"\(build)\","
        json += "\"os_version\":\"\(osVersion)\","
        json += "\"device\":\"\(deviceModel)\","
        json += "\"session_id\":\"\(sessionId)\","
        json += "\"device_id\":\"\(deviceId)\","
        json += "\"occurred_at\":\"\(timestamp)\","
        json += "\"threads\":[{\"index\":0,\"crashed\":true,\"frames\":["
        json += crashFrames.enumerated().map { idx, frame in
            "{\"index\":\(idx),\"image\":\"app\",\"address\":\"\(frame["address"] ?? "0x0")\",\"offset\":0}"
        }.joined(separator: ",")
        json += "]}]}"

        // Write using the write() syscall — async-signal-safe.
        let fd = open(fileName, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        json.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
        close(fd)
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "EXC_BAD_ACCESS (SIGSEGV)"
        case SIGBUS:  return "EXC_BAD_ACCESS (SIGBUS)"
        case SIGILL:  return "EXC_BAD_INSTRUCTION (SIGILL)"
        case SIGFPE:  return "EXC_ARITHMETIC (SIGFPE)"
        case SIGTRAP: return "EXC_BREAKPOINT (SIGTRAP)"
        default:      return "Unknown Signal \(signal)"
        }
    }

    private static func signalReason(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "Abort trap"
        case SIGSEGV: return "Segmentation fault"
        case SIGBUS:  return "Bus error"
        case SIGILL:  return "Illegal instruction"
        case SIGFPE:  return "Floating point exception"
        default:      return "Signal \(signal)"
        }
    }
}
