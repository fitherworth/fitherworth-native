import Foundation
import UIKit

/// Append-only JSONL logger that persists BEFORE the web runtime starts.
/// File: Library/Application Support/NativeDiagnostics/wkwebview.jsonl
final class NativeDiagnostics {
    static let shared = NativeDiagnostics()

    private let queue = DispatchQueue(label: "com.fitherworth.diagnostics", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// In-memory mirror so the DIAG viewer works even if disk writes fail.
    private(set) var memoryLog: [String] = []

    private(set) var didFinishNavigation = false
    private(set) var lastError: String?

    var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("wkwebview.jsonl")
    }

    // MARK: - Core

    func log(_ event: String, _ fields: [String: Any] = [:]) {
        var payload: [String: Any] = fields
        payload["event"] = event
        payload["ts"] = formatter.string(from: Date())
        payload["uptime"] = ProcessInfo.processInfo.systemUptime

        if event == "navigation_finish" { didFinishNavigation = true }
        if event.contains("fail") || event.contains("terminate") {
            lastError = "\(event): \(fields["error_description"] ?? fields["reason"] ?? "unknown")"
        }

        let line: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            line = str
        } else {
            line = "{\"event\":\"\(event)\",\"serialize_failed\":true}"
        }

        NSLog("[FHW-DIAG] %@", line)

        queue.async { [weak self] in
            guard let self else { return }
            self.memoryLog.append(line)
            if self.memoryLog.count > 500 { self.memoryLog.removeFirst(self.memoryLog.count - 500) }
            self.append(line: line)
        }
    }

    private func append(line: String) {
        let url = fileURL
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Convenience

    /// Call as early as possible in AppDelegate.
    func startLaunch() {
        let info = Bundle.main.infoDictionary ?? [:]
        log("native_launch", [
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "version": info["CFBundleShortVersionString"] as? String ?? "?",
            "build": info["CFBundleVersion"] as? String ?? "?",
            "ios": UIDevice.current.systemVersion,
            "model": UIDevice.current.model,
            "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            "log_path": fileURL.path,
        ])
    }

    func lifecycle(_ name: String) {
        log("application_lifecycle", ["phase": name])
    }

    func readAll() -> String {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty {
            return text
        }
        return memoryLog.joined(separator: "\n")
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.memoryLog.removeAll()
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    /// Classifies a URL as the expected remote origin or a local www fallback.
    static func classify(_ url: URL?) -> String {
        guard let url else { return "nil" }
        if url.isFileURL { return "local_file_fallback" }
        switch url.scheme?.lowercased() {
        case "capacitor", "ionic": return "local_www_fallback"
        case "http", "https":
            return url.host?.contains("fitherworth.com") == true ? "remote_expected" : "remote_other"
        default:
            return "other"
        }
    }
}
