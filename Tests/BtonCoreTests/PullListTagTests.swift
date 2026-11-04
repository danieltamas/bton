@testable import BtonCore
import Testing

@Test func pullListTagIsTheKnownOneOn304AndTheHeadersOn200() {
    let notModified = "HTTP/2.0 304 Not Modified\nCache-Control: private\n\n"
    #expect(GitHubClient.listTag(fromResponse: notModified, known: "W/\"a\"") == "W/\"a\"")
    let fresh = "HTTP/2.0 200 OK\nContent-Type: application/json\nEtag: W/\"b\"\n\n[{\"etag:\": 1}]"
    #expect(GitHubClient.listTag(fromResponse: fresh, known: "W/\"a\"") == "W/\"b\"")
    #expect(GitHubClient.listTag(fromResponse: "HTTP/2.0 200 OK\n\n[]", known: nil) == nil)
}
