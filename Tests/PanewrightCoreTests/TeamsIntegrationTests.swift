import Foundation
import Testing

@testable import PanewrightCore

@Suite struct MicrosoftAuthTests {
    @Test func pkceChallengeIsDerivedFromTheVerifier() {
        let a = MicrosoftAuth.makePKCE()
        let b = MicrosoftAuth.makePKCE()
        // Fresh entropy per sign-in — a reused verifier would defeat PKCE.
        #expect(a.verifier != b.verifier)
        // base64url: no padding or URL-unsafe characters.
        for value in [a.verifier, a.challenge] {
            #expect(!value.contains("="))
            #expect(!value.contains("+"))
            #expect(!value.contains("/"))
            #expect(!value.isEmpty)
        }
        // S256, not plain — challenge must differ from the verifier.
        #expect(a.challenge != a.verifier)
    }

    @Test func authorizeURLCarriesPKCEAndRedirect() throws {
        let pkce = MicrosoftAuth.makePKCE()
        let url = try #require(
            MicrosoftAuth.authorizeURL(
                clientID: "abc-123", tenant: "", pkce: pkce, state: "st8"))
        let items = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        // Empty tenant means "common" — any work, school, or personal account.
        #expect(url.absoluteString.hasPrefix("https://login.microsoftonline.com/common/"))
        #expect(value("client_id") == "abc-123")
        #expect(value("response_type") == "code")
        #expect(value("code_challenge") == pkce.challenge)
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "st8")
        #expect(value("redirect_uri") == "panewright://msauth")
        // offline_access is what keeps sign-in alive across restarts.
        #expect(value("scope")?.contains("offline_access") == true)
        #expect(value("scope")?.contains("Calendars.Read") == true)
        // A public client must never carry a secret.
        #expect(value("client_secret") == nil)
    }

    @Test func expiryLeavesRoomToRefresh() {
        let live = MicrosoftAuth.Tokens(
            accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(600))
        // Refreshes early rather than racing the boundary mid-request.
        let nearlyDone = MicrosoftAuth.Tokens(
            accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(30))
        #expect(live.isExpired == false)
        #expect(nearlyDone.isExpired == true)
    }
}

@Suite struct TeamsProviderTests {
    /// The shape Graph returns from /me/calendarView.
    private func payload(_ events: String) -> Data {
        Data(#"{"value":[\#(events)]}"#.utf8)
    }

    private func event(
        id: String, subject: String, start: String, end: String,
        join: String? = nil, allDay: Bool = false
    ) -> String {
        let online = join.map { #""onlineMeeting":{"joinUrl":"\#($0)"},"# } ?? ""
        return """
            {"id":"\(id)","subject":"\(subject)",\(online)\
            "isAllDay":\(allDay),\
            "start":{"dateTime":"\(start)"},"end":{"dateTime":"\(end)"}}
            """
    }

    @Test func parsesMeetingsAndJoinLinks() throws {
        let data = payload(
            event(
                id: "1", subject: "Standup", start: "2026-07-24T15:00:00.0000000",
                end: "2026-07-24T15:15:00.0000000",
                join: "https://teams.microsoft.com/l/meetup-join/abc"))
        let meetings = try TeamsProvider.parse(data)
        #expect(meetings.count == 1)
        let meeting = try #require(meetings.first)
        #expect(meeting.subject == "Standup")
        #expect(meeting.joinURL == "https://teams.microsoft.com/l/meetup-join/abc")
        #expect(meeting.isJoinable)
        #expect(meeting.durationText == "15m")
    }

    @Test func allDayBlocksAreNotJoinable() throws {
        let data = payload(
            event(
                id: "2", subject: "Vacation", start: "2026-07-24T00:00:00.0000000",
                end: "2026-07-25T00:00:00.0000000", allDay: true))
        let meeting = try #require(try TeamsProvider.parse(data).first)
        // A day-long block shouldn't be offered as something to join.
        #expect(meeting.isJoinable == false)
        #expect(TeamsProvider.upNext([meeting]) == nil)
    }

    @Test func upNextPrefersAMeetingAlreadyRunning() {
        let now = Date()
        func make(_ id: String, _ startOffset: TimeInterval, _ endOffset: TimeInterval)
            -> TeamsProvider.Meeting
        {
            .init(
                id: id, subject: id, start: now.addingTimeInterval(startOffset),
                end: now.addingTimeInterval(endOffset), joinURL: "https://x", isAllDay: false)
        }
        let running = make("running", -300, 900)
        let later = make("later", 1800, 3600)
        #expect(TeamsProvider.upNext([running, later])?.id == "running")
        #expect(TeamsProvider.upNext([later])?.id == "later")
    }

    @Test func barLabelCountsDownAndTruncates() {
        let now = Date()
        let soon = TeamsProvider.Meeting(
            id: "1", subject: "Standup", start: now.addingTimeInterval(12 * 60),
            end: now.addingTimeInterval(27 * 60), joinURL: nil, isAllDay: false)
        #expect(TeamsProvider.barLabel(for: soon) == "Standup · 12m")

        let running = TeamsProvider.Meeting(
            id: "2", subject: "Sprint Planning Review Session",
            start: now.addingTimeInterval(-60), end: now.addingTimeInterval(600),
            joinURL: nil, isAllDay: false)
        let label = try? #require(TeamsProvider.barLabel(for: running))
        // Long subjects are trimmed so the chip stays a chip.
        #expect(label?.hasSuffix("· now") == true)
        #expect((label?.count ?? 99) <= 26)
        #expect(TeamsProvider.barLabel(for: nil) == nil)
    }
}
