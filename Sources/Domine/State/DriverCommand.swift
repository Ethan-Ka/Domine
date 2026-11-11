import Foundation

/// The root shell commands behind Install and Remove, mirroring
/// Installer/scripts/postinstall. Every path is single-quoted.
enum DriverCommand {
    static let restartAudio =
        "(/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod)"

    static func install(from source: String, to destination: String) -> String {
        let folder = (destination as NSString).deletingLastPathComponent
        return [
            "/bin/mkdir -p \(quote(folder))",
            "/bin/rm -rf \(quote(destination))",
            "/usr/bin/ditto \(quote(source)) \(quote(destination))",
            "/usr/sbin/chown -R root:wheel \(quote(destination))",
            restartAudio,
        ].joined(separator: " && ")
    }

    static func remove(at destination: String) -> String {
        "/bin/rm -rf \(quote(destination)) && \(restartAudio)"
    }

    /// One shell word: wrapped in single quotes, each `'` closed, escaped and reopened.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `do shell script` with the admin prompt, both strings as AppleScript literals.
    static func appleScript(_ command: String, prompt: String) -> String {
        "do shell script \(literal(command)) with administrator privileges with prompt \(literal(prompt))"
    }

    static func literal(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
