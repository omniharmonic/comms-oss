import CommsClient
import CommsCore
import Foundation

/// The demo's people and triage: synthetic contacts (555 numbers, example.test addresses)
/// for the contact cards, the group members they appear as, and a Prism triage status on
/// every demo thread so each Filter › Status choice shows something. Synthetic data only.
public enum DemoPeople {
    public static let alice = "p_demo_alice"
    public static let maya = "p_demo_maya"
    public static let theo = "p_demo_theo"
    public static let priya = "p_demo_priya"
    public static let noor = "p_demo_noor"

    /// Triage status (wire) per thread.
    static let statuses: [String: String] = [
        "th_stg0": "unclassified", "th_stg1": "informational", "th_stg2": "action-required",
        "th_demo_maya": "social", "th_demo_climbers": "informational", "th_demo_ivy": "action-required",
        "th_demo_jamie": "handled", "th_demo_theo": "urgent", "th_demo_jonah": "social",
        "th_demo_lena": "low", "th_demo_guild": "informational", "th_demo_billing": "action-required",
        "th_demo_stranger": "unclassified", "th_demo_deals": "low", "th_demo_roommates": "handled",
        "th_demo_prize": "unclassified", "th_demo_alice_tg": "social", "th_demo_maya_wa": "informational",
    ]

    /// The vault person of each DM that has one.
    static let threadPeople: [String: String] = [
        "th_stg2": alice, "th_demo_alice_tg": alice,
        "th_demo_maya": maya, "th_demo_maya_wa": maya,
        "th_demo_theo": theo,
    ]

    static func contact(_ id: String) -> CommsContact {
        switch id {
        case alice:
            return CommsContact(
                phones: [.init(label: "mobile", value: "+15550001")],
                emails: [.init(label: "home", value: "alice@example.test")],
                handles: [.init(network: .whatsapp, value: "+15550001", kind: .phone),
                          .init(network: .telegram, value: "@alice_example", kind: .username)])
        case maya:
            return CommsContact(
                phones: [.init(label: "mobile", value: "+15550102233")],
                emails: [.init(value: "maya@example.test")],
                handles: [.init(network: .whatsapp, value: "+15550102233", kind: .phone),
                          .init(network: .signal, value: "+15550102233", kind: .phone)])
        case theo:
            return CommsContact(
                phones: [.init(label: "mobile", value: "+15550104411")],
                handles: [.init(network: .whatsapp, value: "+15550104411", kind: .phone)])
        case priya:
            return CommsContact(handles: [.init(network: .telegram, value: "@priya_n", kind: .username)])
        default:
            return CommsContact()
        }
    }

    static let people: [(id: String, name: String, avatar: CommsAvatar?)] = [
        (alice, "Alice Example", .monogram("AE", members: [])),
        (maya, "Maya Okafor", .token("demo-avatar-maya")),
        (theo, "Theo Marsh", .monogram("TM", members: [])),
        (priya, "Priya Natarajan", .token("demo-avatar-priya")),
        (noor, "Noor Haddad", .token("demo-avatar-noor")),
    ]

    /// Program the backend: statuses on the staging rooms, people, DM contacts and group
    /// members that resolve to people.
    static func install(on backend: FixtureBackend) {
        // Upserting puts a thread on top: newest-first order is kept by going oldest first.
        for id in ["th_stg2", "th_stg1", "th_stg0"] {
            guard var t = backend.currentThread(id: id) else { continue }
            t.status = statuses[id].map(CommsThreadStatus.init(wire:))
            t.personId = threadPeople[id]
            backend.upsertThread(t)
        }
        for p in people {
            backend.setPerson(CommsPerson(id: p.id, name: p.name, avatar: p.avatar, noteId: "note_\(p.id)", contact: contact(p.id)))
        }
        for (threadID, personID) in threadPeople {
            guard let t = backend.currentThread(id: threadID) else { continue }
            let members = backend.currentMembers(id: threadID)
            backend.setThreadDetail(FixtureMessages.detail(t, members: members, contact: contact(personID)))
        }
        // Trail Crew: "alice" is Alice Example.
        if let crew = backend.currentThread(id: "th_stg1") {
            let members = backend.currentMembers(id: "th_stg1").map { m in
                m.id == "@alice:staging.local" ? CommsMember(id: m.id, name: "Alice Example", avatar: m.avatar, personId: alice) : m
            }
            backend.setThreadDetail(FixtureMessages.detail(crew, members: members))
        }
        // Weekend Climbers: three friends, two of them known people, plus Maya.
        if let climbers = backend.currentThread(id: "th_demo_climbers") {
            backend.setThreadDetail(FixtureMessages.detail(climbers, members: [
                CommsMember(id: "@whatsapp_15550102233:example.test", name: "Maya Okafor", avatar: .token("demo-avatar-maya"), personId: maya),
                CommsMember(id: "@whatsapp_priyanatarajan:example.test", name: "Priya Natarajan", avatar: .token("demo-avatar-priya"), personId: priya),
                CommsMember(id: "@whatsapp_noorhaddad:example.test", name: "Noor Haddad", avatar: .token("demo-avatar-noor"), personId: noor),
                CommsMember(id: "@whatsapp_elibrandt:example.test", name: "Eli Brandt", avatar: .token("demo-avatar-eli")),
            ]))
        }
    }
}
