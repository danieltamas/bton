import Foundation

/// A move's `proof`: argv that must fail before the agent works and pass after it pushed. A proof
/// that passes before the work shows nothing is wrong, so the move is refused rather than spent;
/// one still red after the push fails the job, and the new head's own move runs it again.
public enum Proof {
    /// Status 0 before the agent: the refusal's detail. Any other status is red, as it must be.
    public static func beforeDetail(_ argv: [String], status: Int32, head: String) -> String? {
        status == 0 ? "proves nothing: `\(argv.joined(separator: " "))` already passes on \(head.prefix(7))" : nil
    }

    /// A non-zero status after the push: the failure's detail. 0 is nil.
    public static func afterDetail(_ argv: [String], status: Int32) -> String? {
        status == 0 ? nil : "proof still red: `\(argv.joined(separator: " "))` exited \(status)"
    }

    /// A proof that did not run (a timeout, a program not found) is never read as red.
    public static func unrunDetail(_ argv: [String], reason: String) -> String {
        "proof: `\(argv.joined(separator: " "))` \(reason)"
    }
}
