@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct EnvironmentRedactionAcceptanceTests {
    @Test func redactsEveryOccurrenceOfEachEligibleValue() {
        let environment = ["TOKEN": "synthetic-token", "SECRET": "abcdefgh"]
        #expect(DispatchPlanner.redact(
            "synthetic-token abcdefgh synthetic-token/abcdefgh", environment: environment
        ) == "[TOKEN] [SECRET] [TOKEN]/[SECRET]")
    }

    @Test func preservesValuesShorterThanEightCharacters() {
        let environment = ["PG_TESTS_REQUIRED": "1", "SHORT": "abcdefg", "EMPTY": ""]
        let text = "1 check, 11 results; abcdefg abcdefg"
        #expect(DispatchPlanner.redact(text, environment: environment) == text)
    }

    @Test(arguments: ["abcd", "synthetic-password"])
    func redactsURLAndEveryStandalonePasswordWithoutFragments(_ password: String) {
        let url = "postgres://synthetic:\(password)@db.example.invalid:5999/app"
        let text = "URL=\(url); password=\(password); again=\(url), \(password)"
        #expect(DispatchPlanner.redact(text, environment: ["DATABASE_URL": url])
                == "URL=[DATABASE_URL]; password=[DATABASE_URL]; again=[DATABASE_URL], [DATABASE_URL]")
    }

    @Test func preservesURLPasswordsShorterThanFourCharacters() {
        let url = "postgres://synthetic:abc@db.example.invalid/app"
        #expect(DispatchPlanner.redact("\(url) password=abc", environment: ["DATABASE_URL": url])
                == "[DATABASE_URL] password=abc")
    }

    @Test func redactsOverlappingValuesLongestFirst() {
        let environment = ["SHORT_SECRET": "abcdefgh", "LONG_SECRET": "abcdefgh-extended"]
        #expect(DispatchPlanner.redact("abcdefgh-extended abcdefgh", environment: environment)
                == "[LONG_SECRET] [SHORT_SECRET]")
    }

    @Test func preservesTextWithNoMatchingValueOrEmptyEnvironment() {
        let text = "Synthetic review: 1 check passed."
        #expect(DispatchPlanner.redact(text, environment: ["TOKEN": "absent-secret"]) == text)
        #expect(DispatchPlanner.redact(text, environment: [:]) == text)
        #expect(DispatchPlanner.redact("", environment: ["TOKEN": "synthetic-token"]) == "")
    }

    @Test(arguments: ["a\nb", "a\r\nb"])
    func rejectsLineFeedValuesNamingTheKey(_ value: String) {
        #expect(WatchedRepo.environmentProblem(["SYNTHETIC_VALUE": value])?
            .contains("SYNTHETIC_VALUE") == true)
    }

    @Test func permitsLoneCarriageReturnInValue() throws {
        let environment = ["SYNTHETIC_VALUE": "left\rright"]
        #expect(WatchedRepo.environmentProblem(environment) == nil)
        #expect(try WatchedRepo.parseEnvironment("SYNTHETIC_VALUE=left\rright") == environment)
    }

    @Test(arguments: ["\n", "\r\n"])
    func parserKeepsVariablesOnSeparateLines(_ newline: String) throws {
        let environment = try WatchedRepo.parseEnvironment("FIRST=a\(newline)SECOND=b")
        #expect(environment == ["FIRST": "a", "SECOND": "b"])
        #expect(environment.values.allSatisfy { !$0.contains("\n") })
    }

    @Test(arguments: ["a\nb", "a\r\nb"])
    func parserRejectsMultilineValueContinuation(_ value: String) {
        do {
            _ = try WatchedRepo.parseEnvironment("SYNTHETIC_VALUE=\(value)")
            Issue.record("A continuation without a variable assignment must throw")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }
}
