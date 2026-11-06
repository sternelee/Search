import Foundation

// The skills: instructions of the person's own, kept as files — one folder
// apiece in the skills folder, each holding a SKILL.md with its name and
// description between --- lines at the top, and its body below. On, they
// are offered to the bot and to the panel that answers about a page; the
// model asks for one when a task fits it, and its words are read then —
// the body never enters a conversation before it's asked for, so a long
// shelf of skills costs a prompt nothing.
//
// Nothing is written here: the skills are the person's own files, made by
// hand or dropped in, and this only reads them. A skill off is one the
// model never hears of.

enum Skills {
    /// One skill as the shelf meets it: the folder it lives in, its name
    /// and description off the frontmatter, its body read when asked for.
    struct Listed: Identifiable, Equatable {
        let id: String
        let name: String
        let description: String
    }

    /// Where the person's skills live.
    static var folder: URL { Store.file("skills") }

    /// Every skill on the shelf, named and described, in the order of
    /// their names. A folder without a SKILL.md isn't one.
    static func discover() -> [Listed] {
        let files = FileManager.default
        guard let held = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var found: [Listed] = []
        for skill in held.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard skill.hasDirectoryPath,
                  let body = try? String(contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8)
            else { continue }
            let (front, _) = matter(body)
            let name = front["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? skill.lastPathComponent
            let told = front["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { continue }
            found.append(Listed(id: skill.lastPathComponent, name: name, description: told))
        }
        return found
    }

    /// The skills the person has on, as the prompts meet them.
    static func listed() -> [Listed] {
        discover().filter { enabled($0.id) }
    }

    /// On until it's switched off, by hand (see Settings › AI).
    static func enabled(_ id: String) -> Bool { !Store.settings.bool(forKey: "skill.off.\(id)") }
    static func setEnabled(_ id: String, _ on: Bool) {
        Store.settings.set(!on, forKey: "skill.off.\(id)")
    }

    /// A skill's body, the frontmatter off it, for the model that asked
    /// for its words. Nil when there's no such skill.
    static func body(_ id: String) -> String? {
        let file = folder.appendingPathComponent(id).appendingPathComponent("SKILL.md")
        guard let whole = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return matter(whole).after.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The --- lines at the top, if there are any, taken apart into what
    /// they say and what follows them. A line of `name: what` or
    /// `description: what`; nothing fancier is read.
    private static func matter(_ whole: String) -> (front: [String: String], after: String) {
        var text = whole
        guard text.hasPrefix("---") else { return ([:], whole) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return ([:], whole) }
        // The first --- opens the frontmatter; the next one closes it.
        var held: [String] = []
        var rest: [String] = []
        var closed = false
        for line in lines.dropFirst() {
            if !closed, line.trimmingCharacters(in: .whitespaces) == "---" {
                closed = true
                continue
            }
            if closed { rest.append(String(line)) } else { held.append(String(line)) }
        }
        guard closed else { return ([:], whole) }
        var front: [String: String] = [:]
        for line in held {
            guard let cut = line.firstIndex(of: ":") else { continue }
            front[String(line[..<cut]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: cut)...])
        }
        text = rest.joined(separator: "\n")
        return (front, text)
    }
}
