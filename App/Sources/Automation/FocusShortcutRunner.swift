import Foundation
import MeetingCore

struct ShortcutListing: Identifiable, Hashable, Sendable {
    var id: String          // identifier (UUID)
    var name: String
}

/// Runs the user's "Meeting Utility: Focus until end" Shortcut via /usr/bin/shortcuts (§12.2).
/// Argument array only; the input file contains just a request ID and deadline; never turns Focus off (§12.3).
final class FocusShortcutRunner: FocusController, @unchecked Sendable {
    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    static let suggestedName = "Meeting Utility: Focus until end"
    static let timeout: TimeInterval = 20
    static let maxOutputBytes = 4096

    private let identifierProvider: @Sendable () -> String?

    init(identifierProvider: @escaping @Sendable () -> String?) { self.identifierProvider = identifierProvider }

    /// `shortcuts list --show-identifiers` — names are not unique, so the identifier is stored (§12.2).
    static func listShortcuts() async -> [ShortcutListing] {
        guard let (out, status) = try? await run(arguments: ["list", "--show-identifiers"], timeout: 10), status == 0 else { return [] }
        return out.split(separator: "\n").compactMap { line in
            guard let open = line.lastIndex(of: "("), line.hasSuffix(")") else { return nil }
            let id = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            let name = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            return UUID(uuidString: id) != nil ? ShortcutListing(id: id, name: name) : nil
        }
    }

    func enableIfNoFocus(until deadline: Date, sessionID: UUID) async -> FocusResult {
        guard let identifier = identifierProvider() else { return .notConfigured }
        let now = Date()
        guard FocusPolicy.validate(deadline: deadline, now: now) else { return .failed("invalid_deadline") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mu-focus-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: dir) }
            let input = dir.appendingPathComponent("input.json")
            let output = dir.appendingPathComponent("output.txt")
            let payload = try JSONEncoder().encode(FocusShortcutInput(requestID: sessionID, deadline: deadline, now: now))
            fm.createFile(atPath: input.path, contents: payload, attributes: [.posixPermissions: 0o600])
            let (_, status) = try await Self.run(arguments: ["run", identifier, "--input-path", input.path, "--output-path", output.path,
                                                             "--output-type", "public.plain-text"], timeout: Self.timeout)
            guard status == 0 else {
                Log.focus.error("focus shortcut exit=\(status, privacy: .public)")
                return .failed("exit_\(status)")
            }
            let data = (try? Data(contentsOf: output)) ?? Data()
            let result = FocusPolicy.parse(output: String(decoding: data.prefix(Self.maxOutputBytes), as: UTF8.self))
            Log.focus.info("focus shortcut result=\(String(describing: result), privacy: .public)")
            return result
        } catch {
            return .failed("timeout_or_launch")
        }
    }

    enum RunError: Error { case timeout }

    /// Runs the CLI with a bounded timeout and bounded stdout.
    static func run(arguments: [String], timeout: TimeInterval) async throws -> (String, Int32) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            let done = OSAllocatedUnfairLockBox(false)
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(256 * 1024)
                if done.swap(true) == false { cont.resume(returning: (String(decoding: data, as: UTF8.self), proc.terminationStatus)) }
            }
            do { try p.run() } catch {
                if done.swap(true) == false { cont.resume(throwing: error) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                if done.swap(true) == false { cont.resume(throwing: RunError.timeout) }
            }
        }
    }
}

final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    func swap(_ new: Bool) -> Bool { lock.withLock { let old = value; value = new; return old } }
}
