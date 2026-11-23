#!/usr/bin/env swift
// Generates CommsKit/Sources/CommsUI/Tokens.swift from design/tokens.json.
//
//   swift scripts/gen-tokens.swift                 # rewrite Tokens.swift in place
//   swift scripts/gen-tokens.swift --stdout        # print instead (the sync test diffs this)
//   swift scripts/gen-tokens.swift --stdout <tokens.json>
//
// The output is checked in. `TokensSyncTests` regenerates it and fails when it differs, so
// an edit to tokens.json without a regenerate (or a hand edit of Tokens.swift) cannot land.
//
// Mapping (generic over the JSON, so a new key appears without touching this script):
// - an object becomes a struct named `<Key>Tokens` (children of `outgoingByNetwork` share
//   `NetworkShade`, since every network has the same {top, bottom, mac});
// - a "#RRGGBB" string becomes a `TokenColor`;
// - a number becomes `CGFloat`, except the integer counts listed in `intKeys`;
// - `bubble.tail.path` becomes `[TailCommand]`.
// Values the JSON schema lacks but CALIBRATION.md measured are emitted as `Tokens.calibration`.

import Foundation

let args = CommandLine.arguments.dropFirst()
let toStdout = args.contains("--stdout")
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repo = scriptDir.deletingLastPathComponent()
let jsonURL = args.first(where: { !$0.hasPrefix("--") }).map { URL(fileURLWithPath: $0) }
    ?? repo.appendingPathComponent("design/tokens.json")
let outURL = repo.appendingPathComponent("CommsKit/Sources/CommsUI/Tokens.swift")

let intKeys: Set<String> = ["version", "timeHeaderGapMinutes", "jumboEmojiMax"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gen-tokens: \(message)\n".utf8))
    exit(1)
}

guard let data = try? Data(contentsOf: jsonURL),
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
else { fail("cannot read \(jsonURL.path)") }

/// JSON key order is not preserved by JSONSerialization; recover it from the source text so
/// the generated file follows tokens.json's order.
let source = String(decoding: data, as: UTF8.self)
func ordered(_ dict: [String: Any]) -> [String] {
    dict.keys.sorted { a, b in
        let ra = source.range(of: "\"\(a)\"")?.lowerBound ?? source.endIndex
        let rb = source.range(of: "\"\(b)\"")?.lowerBound ?? source.endIndex
        return ra == rb ? a < b : ra < rb
    }
}

func typeName(_ key: String) -> String { key.prefix(1).uppercased() + key.dropFirst() + "Tokens" }

func isColor(_ v: Any) -> Bool {
    guard let s = v as? String else { return false }
    return s.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
}

func num(_ v: Any) -> String {
    let d = (v as! NSNumber).doubleValue
    if d == d.rounded() && abs(d) < 1e9 { return String(Int(d)) }
    return String(d)
}

func colorLiteral(_ hex: String) -> String { "TokenColor(\"\(hex.uppercased())\")" }

var structs: [String] = []

/// Emit a struct for `dict` and return its type name.
func emit(_ dict: [String: Any], path: [String], name: String) -> String {
    var fields: [String] = []
    var colors: [String] = []
    var shades: [String] = []
    for key in ordered(dict) {
        let value = dict[key]!
        let keyPath = path + [key]
        if key == "path", path.last == "tail", let cmds = value as? [[Any]] {
            let items = cmds.map { cmd -> String in
                let op = cmd[0] as! String
                let n = cmd.dropFirst().map(num)
                switch op {
                case "M": return "        .move(CGPoint(x: \(n[0]), y: \(n[1]))),"
                case "L": return "        .line(CGPoint(x: \(n[0]), y: \(n[1]))),"
                case "C": return "        .curve(CGPoint(x: \(n[0]), y: \(n[1])), CGPoint(x: \(n[2]), y: \(n[3])), CGPoint(x: \(n[4]), y: \(n[5]))),"
                case "Z": return "        .close,"
                default: fail("unknown tail command \(op)")
                }
            }
            fields.append("    public let path: [TailCommand] = [\n" + items.joined(separator: "\n") + "\n    ]")
        } else if let obj = value as? [String: Any] {
            let childType: String
            if key == "outgoingByNetwork" {
                childType = emitNetworks(obj, path: keyPath)
            } else {
                childType = emit(obj, path: keyPath, name: typeName(key))
            }
            fields.append("    public let \(key) = \(childType)()")
        } else if isColor(value) {
            fields.append("    public let \(key) = \(colorLiteral(value as! String))")
            colors.append(key)
        } else if value is NSNumber {
            let type = intKeys.contains(key) ? "Int" : "CGFloat"
            fields.append("    public let \(key): \(type) = \(num(value))")
        } else if let s = value as? String {
            fields.append("    public let \(key) = \"\(s)\"")
        } else {
            fail("unsupported value at \(keyPath.joined(separator: "."))")
        }
        if key == "outgoingByNetwork" { shades.append(key) }
    }
    var body = "public struct \(name): Sendable {\n" + fields.joined(separator: "\n")
    if !colors.isEmpty || !shades.isEmpty {
        let direct = colors.map { "(\"\($0)\", \($0))" }.joined(separator: ", ")
        var lines = ["    /// Every colour in this group (network shades flattened as `outgoingByNetwork.<net>.<shade>`)."]
        lines.append("    public var all: [(name: String, color: TokenColor)] {")
        lines.append("        var out: [(name: String, color: TokenColor)] = [\(direct)]")
        for s in shades {
            lines.append("        for (net, shade) in \(s).all {")
            lines.append("            out += [(\"\(s).\\(net).top\", shade.top), (\"\(s).\\(net).bottom\", shade.bottom), (\"\(s).\\(net).mac\", shade.mac)]")
            lines.append("        }")
        }
        lines.append("        return out")
        lines.append("    }")
        body += "\n\n" + lines.joined(separator: "\n")
    }
    body += "\n}"
    structs.append(body)
    return name
}

func emitNetworks(_ dict: [String: Any], path: [String]) -> String {
    var fields: [String] = []
    var names: [String] = []
    for net in ordered(dict) {
        guard let shade = dict[net] as? [String: Any],
              let top = shade["top"] as? String, let bottom = shade["bottom"] as? String, let mac = shade["mac"] as? String,
              isColor(top), isColor(bottom), isColor(mac), shade.count == 3
        else { fail("outgoingByNetwork.\(net) must be {top, bottom, mac} colours") }
        fields.append("    public let \(net) = NetworkShade(top: \(colorLiteral(top)), bottom: \(colorLiteral(bottom)), mac: \(colorLiteral(mac)))")
        names.append(net)
    }
    let all = names.map { "(\"\($0)\", \($0))" }.joined(separator: ", ")
    let body = "public struct OutgoingByNetworkTokens: Sendable {\n" + fields.joined(separator: "\n")
        + "\n\n    /// Every network's shade, in tokens.json order.\n    public var all: [(network: String, shade: NetworkShade)] { [\(all)] }\n}"
    structs.append(body)
    return "OutgoingByNetworkTokens"
}

var top: [String] = []
for key in ordered(root) {
    let value = root[key]!
    if let obj = value as? [String: Any] {
        top.append("    public static let \(key) = \(emit(obj, path: [key], name: typeName(key)))()")
    } else if value is NSNumber {
        top.append("    public static let \(key): \(intKeys.contains(key) ? "Int" : "CGFloat") = \(num(value))")
    } else {
        fail("unsupported top-level value \(key)")
    }
}

let header = """
// GENERATED by scripts/gen-tokens.swift from design/tokens.json. DO NOT EDIT.
// Regenerate: swift scripts/gen-tokens.swift  (TokensSyncTests fails when this file is stale.)

import CoreGraphics

/// The design tokens (design/tokens.json; provenance of every value in design/CALIBRATION.md).
public enum Tokens {
\(top.joined(separator: "\n"))
    /// Measured values the tokens.json schema has no key for (design/CALIBRATION.md).
    public static let calibration = CalibrationTokens()
}

"""

let support = """
/// An sRGB colour from tokens.json.
public struct TokenColor: Sendable, Hashable, CustomStringConvertible {
    public let hex: String
    public let red: Double, green: Double, blue: Double

    public init(_ hex: String) {
        self.hex = hex
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        red = Double((v >> 16) & 0xFF) / 255
        green = Double((v >> 8) & 0xFF) / 255
        blue = Double(v & 0xFF) / 255
    }

    public var description: String { hex }
}

/// One network's outgoing blue: `top`/`bottom` of the iOS window-space gradient, `mac` solid.
public struct NetworkShade: Sendable, Hashable {
    public let top: TokenColor, bottom: TokenColor, mac: TokenColor
}

/// One command of `bubble.tail.path` (points; origin at the bubble's bottom-outer corner,
/// +x inward, +y down — see CALIBRATION.md "tail.path convention").
public enum TailCommand: Sendable, Hashable {
    case move(CGPoint)
    case line(CGPoint)
    case curve(CGPoint, CGPoint, CGPoint)
    case close
}

/// Values measured in design/CALIBRATION.md ("Measured, but no tokens key yet") that the
/// fixed tokens.json schema cannot hold. Edit them in scripts/gen-tokens.swift.
public struct CalibrationTokens: Sendable {
    /// Typing bubble ≈ 55 × 34 pt (CALIBRATION: 9to5 crop at 3.13 px/pt).
    public let typingBubbleWidth: CGFloat = 55
    public let typingBubbleHeight: CGFloat = 34
    /// Typing dots: 3 × ≈ 8 pt; #808080 active, #ABABAD resting (CALIBRATION).
    public let typingDot: CGFloat = 8
    public let typingDotActive = TokenColor("#808080")
    public let typingDotResting = TokenColor("#ABABAD")
    /// Mac single-line bubble height 28.5 pt, a capsule (CALIBRATION: newsroom Mac render at a
    /// checked 1.156 px/pt; the Mac guide PNG is ≈ 0.81 px/pt, ruling R19).
    public let macBubbleHeight: CGFloat = 28.5
    /// Tapback badge centre ≈ 2 pt inside the bubble's trailing edge and ≈ 11 pt above its
    /// top, with a two-dot thought tail toward the bubble (CALIBRATION: transcript.tapbackBadge).
    public let tapbackInsetFromEdge: CGFloat = 2
    public let tapbackRiseAboveTop: CGFloat = 11
    /// Transcript side margins: 16 pt compact, 20 pt regular (CALIBRATION: kit layout guide).
    public let sideMarginCompact: CGFloat = 16
    public let sideMarginRegular: CGFloat = 20
}
"""

let output = header + "\n" + structs.joined(separator: "\n\n") + "\n\n" + support + "\n"

if toStdout {
    print(output, terminator: "")
} else {
    do { try output.write(to: outURL, atomically: true, encoding: .utf8) } catch { fail("cannot write \(outURL.path): \(error)") }
    print("wrote \(outURL.path)")
}
