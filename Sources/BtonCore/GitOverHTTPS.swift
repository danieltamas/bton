import Foundation

extension Dispatcher {
    /// The agent's git reaches GitHub over HTTPS with gh's credential, as Bton's own does: an SSH
    /// remote needs `~/.ssh`, which Claude Code's sandbox may not let it read.
    static func gitOverHTTPS(ghPath: String) -> [String: String] {
        let settings = [
            ("url.https://github.com/.insteadOf", "git@github.com:"),
            ("url.https://github.com/.insteadOf", "ssh://git@github.com/"),
            ("credential.https://github.com.helper", ""),
            ("credential.https://github.com.helper", "!\(ghPath) auth git-credential"),
        ]
        var environment = ["GIT_CONFIG_COUNT": String(settings.count), "GIT_TERMINAL_PROMPT": "0"]
        for (index, (key, value)) in settings.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = key
            environment["GIT_CONFIG_VALUE_\(index)"] = value
        }
        return environment
    }
}
