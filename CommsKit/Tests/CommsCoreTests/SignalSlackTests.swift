import CommsClient
import Foundation
import PrismModels
import XCTest
@testable import CommsCore

/// The Signal and Slack bridges (Prism prism-v2026.11.22-4): the server sends `"signal"` and
/// `"slack"` as network strings, and a Slack thread names its workspace in
/// `channels[0].accountLabel`. Synthetic shapes only.
final class SignalSlackTests: XCTestCase {
    private func thread(_ json: String) throws -> CommsThread {
        try PrismJSON.decoder().decode(CommsThread.self, from: Data(json.utf8))
    }

    private let slackChannel = """
    {"id":"th_s1","title":"incident-review-2","titleSource":"room","avatar":{"monogram":"I"},"kind":"group",
     "networks":["slack"],"lastActivityAt":"2026-11-22T10:00:00.000Z","unread":{"count":2,"trusted":true},
     "folder":"inbox","urgency":null,"pinned":false,"muted":false,
     "channels":[{"network":"slack","accountLabel":"Example Workspace",
                  "capabilities":{"react":true,"edit":true,"unsend":true,"reply":true,"typing":true,"receipts":false,"attachments":true}}]}
    """

    func testSlackThreadDecodesWithWorkspace() throws {
        let t = try thread(slackChannel)
        XCTAssertEqual(t.networks, [.slack])
        XCTAssertEqual(t.channels.first?.network, .slack)
        XCTAssertEqual(t.accountLabel, "Example Workspace")
        XCTAssertEqual(t.kind, .group)
        XCTAssertEqual(t.title, "incident-review-2", "kebab-case channel names are titles, kept as sent")
        XCTAssertEqual(CommsNetwork.slack.displayName, "Slack")
        // Round-trips unchanged (the wire string is kept).
        let again = try PrismJSON.decoder().decode(CommsThread.self, from: PrismJSON.encoder().encode(t))
        XCTAssertEqual(again.networks.first?.wire, "slack")
    }

    func testSignalDMDecodesWithoutAccount() throws {
        let t = try thread(slackChannel
            .replacingOccurrences(of: "\"slack\"", with: "\"signal\"")
            .replacingOccurrences(of: "\"Example Workspace\"", with: "null")
            .replacingOccurrences(of: "\"group\"", with: "\"dm\""))
        XCTAssertEqual(t.networks, [.signal])
        XCTAssertNil(t.accountLabel)
        XCTAssertEqual(CommsNetwork.signal.displayName, "Signal")
    }

    func testBlankAccountLabelIsNoAccount() throws {
        let t = try thread(slackChannel.replacingOccurrences(of: "\"Example Workspace\"", with: "\"  \""))
        XCTAssertNil(t.accountLabel)
    }

    func testNetworkFilterAdmitsAndQueriesSlackAndSignal() throws {
        let slack = try thread(slackChannel)
        XCTAssertTrue(FilterState(networks: [.slack]).admits(slack))
        XCTAssertFalse(FilterState(networks: [.signal]).admits(slack))
        XCTAssertTrue(FilterState(networks: [CommsNetwork(wire: "slack")]).admits(slack))
        XCTAssertEqual(FilterState(networks: [.slack, .signal, .whatsapp]).query().networks.map(\.wire), ["signal", "slack", "whatsapp"])
    }
}
