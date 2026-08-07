import Foundation

/// Plain stdout/stderr logging (redirected to a file by the LaunchAgent
/// plist in deployment) — deliberately not a structured logging framework,
/// since a log-line-per-request is all this service needs.
///
/// A fresh ISO8601DateFormatter per call rather than a shared global: the
/// class isn't Sendable, and logging isn't hot enough for the allocation to
/// matter.
func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = "[\(formatter.string(from: Date()))] \(message)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}
