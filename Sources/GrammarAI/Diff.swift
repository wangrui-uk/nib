import SwiftUI

/// Word-level diff, for counting fixes and showing suggestions.
enum WordDiff {
    enum Piece { case same(String), removed(String), added(String) }

    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var curIsSpace: Bool?
        for ch in s {
            let sp = ch.isWhitespace
            if curIsSpace != nil && sp != curIsSpace { out.append(cur); cur = "" }
            cur.append(ch)
            curIsSpace = sp
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func diff(_ a: String, _ b: String) -> [Piece] {
        let ta = tokens(a), tb = tokens(b)
        let d = tb.difference(from: ta)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in d {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var raw: [Piece] = []
        var i = 0, j = 0
        while i < ta.count || j < tb.count {
            if i < ta.count, removed.contains(i) { raw.append(.removed(ta[i])); i += 1 }
            else if j < tb.count, inserted.contains(j) { raw.append(.added(tb[j])); j += 1 }
            else if i < ta.count, j < tb.count { raw.append(.same(ta[i])); i += 1; j += 1 }
            else { break }
        }
        // Merge runs of the same kind.
        var out: [Piece] = []
        for p in raw {
            switch (out.last, p) {
            case (.same(let x)?, .same(let y)): out[out.count - 1] = .same(x + y)
            case (.removed(let x)?, .removed(let y)): out[out.count - 1] = .removed(x + y)
            case (.added(let x)?, .added(let y)): out[out.count - 1] = .added(x + y)
            default: out.append(p)
            }
        }
        return out
    }

    /// The changes as UTF-16 ranges in `a` (what AX and NSString use) with their replacement text.
    static func edits(_ a: String, _ b: String) -> [(range: NSRange, text: String)] {
        var out: [(range: NSRange, text: String)] = []
        var pos = 0
        var start: Int?
        var len = 0
        var text = ""
        func flush() {
            if let st = start { out.append((NSRange(location: st, length: len), text)) }
            start = nil; len = 0; text = ""
        }
        for p in diff(a, b) {
            switch p {
            case .same(let s): flush(); pos += s.utf16.count
            case .removed(let s): if start == nil { start = pos }; len += s.utf16.count; pos += s.utf16.count
            case .added(let s): if start == nil { start = pos }; text += s
            }
        }
        flush()
        return out
    }

    /// Number of separate changed places.
    static func issueCount(_ a: String, _ b: String) -> Int {
        var count = 0, inChange = false
        for p in diff(a, b) {
            if case .same = p { inChange = false; continue }
            if !inChange { count += 1; inChange = true }
        }
        return max(count, a == b ? 0 : 1)
    }

    static func text(_ pieces: [Piece]) -> Text {
        var acc = Text("")
        var prevRemoved = false
        for p in pieces {
            switch p {
            case .same(let s): acc = acc + Text(abbreviate(s)); prevRemoved = false
            case .removed(let s): acc = acc + PopupStyle.removed(s); prevRemoved = true
            case .added(let s):
                // Display only: a space between the old and new word so they don't run together.
                acc = acc + Text(prevRemoved && !s.hasPrefix(" ") ? " " : "") + PopupStyle.added(s)
                prevRemoved = false
            }
        }
        return acc
    }

    static func abbreviate(_ s: String) -> String {
        guard s.count > 140 else { return s }
        return String(s.prefix(60)) + " … " + String(s.suffix(60))
    }
}
