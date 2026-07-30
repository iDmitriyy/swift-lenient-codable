import Foundation
import LenientCodable

struct Test {
    @NilOnFailure var omr: Int?
    @Strict var om: Int
}

// MARK: - Dictionary leniency demo

enum Subject: String, Codable {
    case math, science, history
}

// One line opts an enum in as a lenient dictionary key.
extension Subject: LenientDictionaryKey {}

@LenientDecodable
struct ReportCard {
    // Implicitly @NilOnFailure: a broken value pads `nil` at its key.
    var scores: [String: Int?]
    // Enum-keyed: an unknown JSON key drops that entry, the rest survive.
    var passed: [Subject: Bool?]
    // @DropOnFailure: broken entries are removed, survivors keep their keys.
    @DropOnFailure var teacherIds: [String: Int]
}

let json = Data("""
{
    "scores": { "math": 91, "science": "N/A", "history": 78 },
    "passed": { "math": true, "science": false, "alchemy": true },
    "teacherIds": { "math": 4, "science": "TBD", "history": 7 }
}
""".utf8)

let card = try JSONDecoder().decode(ReportCard.self, from: json)

print("scores — [String: Int?], \"science\" was \"N/A\" (not an Int) → padded nil:")
for (subject, score) in card.scores.sorted(by: { $0.key < $1.key }) {
    print("  \(subject): \(score.map(String.init) ?? "nil")")
}

print("passed — [Subject: Bool?], \"alchemy\" is not a Subject → entry dropped:")
for (subject, passed) in card.passed.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
    print("  \(subject.rawValue): \(passed.map(String.init) ?? "nil")")
}

print("teacherIds — @DropOnFailure [String: Int], \"science\" was \"TBD\" → entry dropped:")
for (subject, id) in card.teacherIds.sorted(by: { $0.key < $1.key }) {
    print("  \(subject): \(id)")
}
