import Foundation
import Testing
import BtonCore

@Suite(ProcessBound())
struct ReleaseLookupAcceptanceTests {
    @Test(arguments: ["", "not JSON", "{}", #"{"tag_name":"v0.2.0"}"#])
    func notFoundMeansNoReleaseRegardlessOfBody(body: String) throws {
        #expect(try ReleaseLookup.decode(Data(body.utf8), status: 404) == .none)
    }

    @Test func successfulResponsePreservesReleaseTag() throws {
        let data = Data(#"{"tag_name":"v0.2.0"}"#.utf8)
        #expect(try ReleaseLookup.decode(data, status: 200) == .released(tag: "v0.2.0"))
    }

    @Test(arguments: ["{}", #"{"message":"No tag"}"#])
    func successfulResponseWithoutTagIsUnreadable(body: String) {
        #expect(throws: ReleaseLookup.Failure.unreadable) {
            try ReleaseLookup.decode(Data(body.utf8), status: 200)
        }
    }

    @Test(arguments: [500, 403])
    func failedAskThrowsHTTPFailureInsteadOfNoRelease(status: Int) {
        for body in ["", #"{"message":"Request failed"}"#, #"{"tag_name":"v0.2.0"}"#] {
            #expect(throws: ReleaseLookup.Failure.http(status)) {
                try ReleaseLookup.decode(Data(body.utf8), status: status)
            }
        }
    }

    @Test func bothStatesRoundTripAsPersistedDictionary() throws {
        let states: [String: ReleaseLookup.State] = [
            "released/project": .released(tag: "v0.2.0"),
            "unreleased/project": .none
        ]
        let data = try JSONEncoder().encode(states)
        let decoded = try JSONDecoder().decode([String: ReleaseLookup.State].self, from: data)
        #expect(decoded == states)
    }
}
