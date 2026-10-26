import Darwin
import Foundation
import Testing

@Suite(ProcessBound())
struct InstallerStopAcceptanceTests {
    @Test func stopsItsOwnParent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parent = try fixture.start(["parent", fixture.script.path, fixture.name, fixture.result.path])
        defer { fixture.stop(parent) }
        try fixture.waitForFile(fixture.ready)
        try #require(try fixture.anyMatchingProcess())
        #expect(parent.isRunning)
        let shell = try String(contentsOf: fixture.ready, encoding: .utf8)
            .split(separator: " ").map { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        #expect(shell.count == 2)
        #expect(shell.last! == parent.processIdentifier)
        try Data().write(to: fixture.directory.appendingPathComponent("go"))
        try fixture.waitForFile(fixture.result, timeout: 120)
        #expect(try String(contentsOf: fixture.result, encoding: .utf8) == "0\n")
        try fixture.waitForExit(parent)
        #expect(parent.terminationReason == .uncaughtSignal)
        #expect(parent.terminationStatus == SIGTERM)
        #expect(try !fixture.anyMatchingProcess())
    }

    @Test func stopsUnrelatedProcesses() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.start(["wait", fixture.ready.path])
        defer { fixture.stop(first) }
        try fixture.waitForFile(fixture.ready)
        let secondReady = fixture.directory.appendingPathComponent("second-ready")
        let second = try fixture.start(["wait", secondReady.path])
        defer { fixture.stop(second) }
        try fixture.waitForFile(secondReady)
        try #require(try fixture.anyMatchingProcess())
        let shell = try fixture.callStop()
        defer { fixture.stop(shell) }
        try fixture.waitForExit(shell)
        #expect(shell.terminationStatus == 0)
        for process in [first, second] {
            try fixture.waitForExit(process)
            #expect(process.terminationReason == .uncaughtSignal)
            #expect(process.terminationStatus == SIGTERM)
        }
        #expect(try !fixture.anyMatchingProcess())
    }

    @Test func absentProcessReturnsZeroPromptly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(try !fixture.anyMatchingProcess())
        let start = Date()
        let shell = try fixture.callStop()
        defer { fixture.stop(shell) }
        try fixture.waitForExit(shell, timeout: 120)
        #expect(shell.terminationStatus == 0)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func escalatesToKillWhenTermIsIgnored() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = try fixture.start(["ignore", fixture.ready.path])
        defer { fixture.stop(target) }
        try fixture.waitForFile(fixture.ready)
        try #require(try fixture.anyMatchingProcess())
        let shell = try fixture.callStop()
        defer { fixture.stop(shell) }
        try fixture.waitForExit(shell, timeout: 120)
        #expect(shell.terminationStatus == 0)
        try fixture.waitForExit(target)
        #expect(target.terminationReason == .uncaughtSignal)
        #expect(target.terminationStatus == SIGKILL)
        #expect(try !fixture.anyMatchingProcess())
    }

    private final class Fixture {
        let directory: URL
        let name = "stop-" + UUID().uuidString
        var executable: URL { directory.appendingPathComponent(name) }
        var script: URL { directory.appendingPathComponent("stop.sh") }
        var result: URL { directory.appendingPathComponent("result") }
        var ready: URL { directory.appendingPathComponent("ready") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                let lines = try String(contentsOf: root.appendingPathComponent("install.sh"), encoding: .utf8)
                    .components(separatedBy: "\n")
                let start = try #require(lines.firstIndex(of: "stop_running() {"))
                let end = try #require(lines.indices.dropFirst(start + 1).first { lines[$0] == "}" })
                // Source only the real function; never execute main or signal the real app.
                let function = directory.appendingPathComponent("function.sh")
                try (lines[start...end].joined(separator: "\n") + "\n")
                    .write(to: function, atomically: true, encoding: .utf8)
                try """
                source "$(dirname "$0")/function.sh"
                if [[ ${3:-} == parent ]]; then
                  echo "$$ $PPID" > "$(dirname "$0")/ready"
                  while [[ ! -e "$(dirname "$0")/go" ]]; do sleep 0.02; done
                fi
                stop_running "$1"
                status=$?
                echo "$status" > "$2"
                exit "$status"
                """.write(to: script, atomically: true, encoding: .utf8)
                let source = directory.appendingPathComponent("fixture.c")
                try """
                #include <signal.h>
                #include <stdio.h>
                #include <string.h>
                #include <unistd.h>
                int main(int argc, char **argv) {
                    if (argc < 3) return 2;
                    if (!strcmp(argv[1], "parent")) {
                        pid_t child = fork();
                        if (child < 0) return 3;
                        if (!child) {
                            execl("/bin/bash", "bash", argv[2], argv[3], argv[4], "parent", (char *)0);
                            _exit(4);
                        }
                    } else {
                        if (!strcmp(argv[1], "ignore")) signal(SIGTERM, SIG_IGN);
                        FILE *ready = fopen(argv[2], "w");
                        if (!ready) return 5;
                        fputs("ready", ready);
                        fclose(ready);
                    }
                    for (;;) pause();
                }
                """.write(to: source, atomically: true, encoding: .utf8)
                let compiler = try launch("/usr/bin/cc", [source.path, "-o", executable.path])
                defer { stop(compiler) }
                try waitForExit(compiler, timeout: 120)
                try #require(compiler.terminationStatus == 0)
            } catch {
                cleanup()
                throw error
            }
        }

        func launch(_ path: String, _ arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            return process
        }

        func start(_ arguments: [String]) throws -> Process {
            try launch(executable.path, arguments)
        }

        func callStop() throws -> Process {
            try launch("/bin/bash", [script.path, name, result.path])
        }

        func waitForFile(_ url: URL, timeout: TimeInterval = 120) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let data = try? Data(contentsOf: url), !data.isEmpty { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
            Issue.record("Timed out waiting for \(url.lastPathComponent)")
            throw Timeout()
        }

        func waitForExit(_ process: Process, timeout: TimeInterval = 120) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            try #require(!process.isRunning, "Process did not exit within \(timeout) seconds")
            process.waitUntilExit()
        }

        func anyMatchingProcess() throws -> Bool {
            let probe = try launch("/usr/bin/pgrep", ["-a", "-x", name])
            defer { stop(probe) }
            try waitForExit(probe)
            try #require(probe.terminationStatus == 0 || probe.terminationStatus == 1,
                         "pgrep cannot enumerate processes in this environment")
            return probe.terminationStatus == 0
        }

        func stop(_ process: Process) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        func cleanup() {
            // The parent test's shell is orphaned when its target dies; retain its exact PID.
            if let text = try? String(contentsOf: ready, encoding: .utf8),
               let token = text.split(separator: " ").first, let pid = Int32(token) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        private struct Timeout: Error {}
    }
}
