import Foundation

/// Today's Microsoft 365 calendar, with the Teams join link for each meeting.
///
/// Reads Microsoft Graph with the token from ``MicrosoftAuth`` — no Outlook or
/// Teams desktop app required, which is the point: sign in once in the browser
/// and the bar knows your next meeting on any Mac.
public struct TeamsProvider: IntegrationProvider {
    public let id = "teams"
    public let displayName = "Teams"
    public let barLabel = "MTG"

    private let clientID: String
    private let tenant: String

    public init(clientID: String, tenant: String = "common") {
        self.clientID = clientID.trimmingCharacters(in: .whitespaces)
        self.tenant = tenant
    }

    public struct Meeting: Equatable, Sendable, Identifiable {
        public var id: String
        public var subject: String
        public var start: Date
        public var end: Date
        public var joinURL: String?
        public var isAllDay: Bool

        /// Whole-day blocks aren't meetings you join; they shouldn't drive the
        /// countdown or steal the "next up" slot.
        public var isJoinable: Bool { !isAllDay && joinURL != nil }

        /// Rounded, not truncated: 11m59s away reads as "12m", which is what a
        /// countdown should say — truncating makes it look a minute closer.
        public var minutesUntilStart: Int {
            Int((start.timeIntervalSinceNow / 60).rounded())
        }

        public var isInProgress: Bool {
            let now = Date()
            return now >= start && now <= end
        }

        public var durationText: String {
            let minutes = max(Int(end.timeIntervalSince(start) / 60), 0)
            if minutes >= 60 {
                let rest = minutes % 60
                return "\(minutes / 60)h\(rest > 0 ? " \(rest)m" : "")"
            }
            return "\(minutes)m"
        }
    }

    /// Today's remaining meetings as panel items — clicking one opens its
    /// Teams join link (or the calendar entry when it isn't an online meeting).
    public func fetch() async throws -> [IntegrationItem] {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return try await meetings().map { meeting in
            let when = formatter.string(from: meeting.start)
            return IntegrationItem(
                id: meeting.id,
                title: meeting.subject,
                subtitle: meeting.isAllDay ? "All day" : "\(when) · \(meeting.durationText)",
                badge: meeting.isInProgress ? "now" : nil,
                url: meeting.joinURL.flatMap(URL.init(string:))
                    ?? URL(string: "https://outlook.office.com/calendar/view/day")!,
                status: meeting.isInProgress ? "In Progress" : nil,
                updated: meeting.start)
        }
    }

    /// Meetings from now through end of day, soonest first.
    public func meetings(session: URLSession = .shared) async throws -> [Meeting] {
        guard !clientID.isEmpty else { throw IntegrationError.missingCredentials(id) }
        guard
            let token = await MicrosoftAuth.validAccessToken(clientID: clientID, tenant: tenant)
        else { throw IntegrationError.missingCredentials(id) }

        // calendarView expands recurring series into concrete occurrences —
        // /events would return the master and miss today's instance.
        let now = Date()
        let endOfDay =
            Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendarView")!
        components.queryItems = [
            .init(name: "startDateTime", value: formatter.string(from: now.addingTimeInterval(-900))),
            .init(name: "endDateTime", value: formatter.string(from: endOfDay)),
            .init(name: "$select", value: "id,subject,start,end,isAllDay,onlineMeeting,onlineMeetingUrl"),
            .init(name: "$orderby", value: "start/dateTime"),
            .init(name: "$top", value: "25"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Ask Graph for UTC so parsing doesn't depend on the mailbox timezone.
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IntegrationError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IntegrationError.http(http.statusCode, "calendar")
        }
        return try Self.parse(data)
    }

    /// Split out so the Graph JSON shape is unit-testable without a network.
    public static func parse(_ data: Data) throws -> [Meeting] {
        struct Payload: Decodable {
            struct Event: Decodable {
                struct Stamp: Decodable { let dateTime: String }
                struct Online: Decodable { let joinUrl: String? }
                let id: String
                let subject: String?
                let start: Stamp
                let end: Stamp
                let isAllDay: Bool?
                let onlineMeeting: Online?
                let onlineMeetingUrl: String?
            }
            let value: [Event]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw IntegrationError.malformedResponse
        }
        // Graph returns UTC without a zone suffix under Prefer: UTC.
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        parser.timeZone = TimeZone(identifier: "UTC")
        let fallback = ISO8601DateFormatter()

        func date(_ raw: String) -> Date? {
            parser.date(from: raw) ?? fallback.date(from: raw)
                ?? fallback.date(from: raw + "Z")
        }
        return payload.value.compactMap { event in
            guard let start = date(event.start.dateTime), let end = date(event.end.dateTime)
            else { return nil }
            return Meeting(
                id: event.id,
                subject: event.subject ?? "(no subject)",
                start: start,
                end: end,
                joinURL: event.onlineMeeting?.joinUrl ?? event.onlineMeetingUrl,
                isAllDay: event.isAllDay ?? false)
        }
        .sorted { $0.start < $1.start }
    }

    /// The meeting the bar should be counting down to: one in progress, else
    /// the next that hasn't started.
    public static func upNext(_ meetings: [Meeting]) -> Meeting? {
        meetings.first { $0.isInProgress && !$0.isAllDay }
            ?? meetings.first { !$0.isAllDay && $0.start > Date() }
    }

    /// Bar text: "Standup 12m", "Standup now", trimmed to fit a chip.
    public static func barLabel(for meeting: Meeting?) -> String? {
        guard let meeting else { return nil }
        let title = meeting.subject.count > 18
            ? String(meeting.subject.prefix(17)) + "…" : meeting.subject
        if meeting.isInProgress { return "\(title) · now" }
        let minutes = max(meeting.minutesUntilStart, 0)
        if minutes >= 60 {
            return "\(title) · \(minutes / 60)h\(minutes % 60 > 0 ? "\(minutes % 60)m" : "")"
        }
        return "\(title) · \(minutes)m"
    }
}
