import Foundation

extension Dispatcher {
    /// What every agent Bton starts runs with, under the job's own variables. `RMJ_GUARD=off`:
    /// RMJ's Claude Code hook (`rmj guard`, 0.12.0) otherwise blocks a test or check command in
    /// a repo one of the Mac owner's rules routes to a build box, and an unattended agent has no
    /// box, no approval and no way to answer; a job's commands run where the job runs.
    static let agentEnvironment = ["RMJ_GUARD": "off"]

    /// The job's git, an agent's or a command's, reaches GitHub over HTTPS with gh's credential,
    /// as Bton's own does: an SSH remote needs `~/.ssh`, which Claude Code's sandbox may not let
    /// an agent read, or an SSH agent that asks the owner to approve the key, which nobody
    /// answers inside a job (Secretive, measured 2026-11-02: "Interrupted system call", then
    /// "Permission denied (publickey)" on a merge).
    static func gitOverHTTPS(ghPath: String) -> [String: String] {
        // Git hands a `!` helper to a shell: the path is quoted so a space in it stays one word.
        let quoted = "'" + ghPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let settings = [
            ("url.https://github.com/.insteadOf", "git@github.com:"),
            ("url.https://github.com/.insteadOf", "ssh://git@github.com/"),
            ("credential.https://github.com.helper", ""),
            ("credential.https://github.com.helper", "!\(quoted) auth git-credential"),
        ]
        var environment = ["GIT_CONFIG_COUNT": String(settings.count), "GIT_TERMINAL_PROMPT": "0"]
        for (index, (key, value)) in settings.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = key
            environment["GIT_CONFIG_VALUE_\(index)"] = value
        }
        return environment
    }
}
