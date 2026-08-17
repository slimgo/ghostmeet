//
//  UserProfile.swift
//  GhostMeet
//

import Foundation

/// Standing facts about the user — role, experience, stack — that are not
/// derivable from the conversation and are filled in ahead of a call, under a
/// name the user gave them: «Тимлид», «Синьор фулстек».
///
/// The profile belongs to the *user*, not to the call: it lives in
/// `SettingsStore` (user-scoped storage), never in session state, which is why
/// clearing the conversation context leaves it untouched.
///
/// **There is one shape of profile, whichever way it was filled in and however
/// many of them the user keeps.** Typing the fields by hand and importing a
/// resume produce a value of this same type; `ProfileLibrary` holds several of
/// them and marks one selected; and exactly one — the selected one — reaches a
/// model, in exactly one shape: `promptFragment`. Nothing in the prompt layer
/// knows that a library exists.
///
/// `promptFragment` is also the shape `ResumeProfilePrompt` asks the model to
/// answer in, which makes `parsed(from:)` its literal inverse rather than a
/// second format that has to be kept in step by hand.
nonisolated struct UserProfile: Codable, Equatable, Identifiable, Sendable {

    /// Identity of this entry in the library. Never shown, never sent anywhere:
    /// it exists so that renaming a profile, or giving two of them the same
    /// name, cannot make the app lose track of which one is selected.
    let id: UUID

    /// What the user calls this profile. Not sent to the model — the model is
    /// told the role, and «Тимлид» as a *name* is a label for the picker, not a
    /// fact about the user.
    var name: String

    /// Job title the user is interviewing for or working as.
    var role: String

    /// Free-form experience summary — years, domains, notable projects.
    var experience: String

    /// Technologies the user actually works with.
    var stack: String

    /// A profile the user has not filled in yet.
    static let empty = UserProfile()

    init(
        id: UUID = UUID(),
        name: String = "",
        role: String = "",
        experience: String = "",
        stack: String = ""
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.experience = experience
        self.stack = stack
    }

    /// Whether the profile says nothing the model could use. The name does not
    /// count: it never reaches a prompt, so a profile with a name and no facts
    /// still adds nothing to the system message.
    var isEmpty: Bool {
        Field.allCases.allSatisfy { self[$0].trimmedOrNil == nil }
    }

    /// Label for the picker. Falls back to the role, and then to a placeholder,
    /// so an unnamed profile is still something the user can point at.
    var displayName: String {
        name.trimmedOrNil ?? role.trimmedOrNil ?? String(localized: "Без названия")
    }

    /// Equality is about what a profile *says*, not which entry it is: two
    /// entries carrying the same name and the same three facts compare equal.
    /// Identity is `id`, and `ProfileLibrary` compares it explicitly wherever
    /// the difference matters.
    static func == (lhs: UserProfile, rhs: UserProfile) -> Bool {
        lhs.name == rhs.name && Field.allCases.allSatisfy { lhs[$0] == rhs[$0] }
    }

    // MARK: - Persistence

    /// Decoded field by field with fallbacks, because a profile written by the
    /// build that had exactly one — and no id and no name — must survive the
    /// upgrade. Losing it would send the user back to typing their experience
    /// in again, and they would find out during an interview.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        experience = try container.decodeIfPresent(String.self, forKey: .experience) ?? ""
        stack = try container.decodeIfPresent(String.self, forKey: .stack) ?? ""
    }

    // MARK: - Fields

    /// The three facts, in the order they are written into a prompt and read
    /// back out of an answer.
    ///
    /// An enum and not three literals scattered about: the labels are wording,
    /// the same wording appears in `docs/GhostMeet-Prompts.md`, and a profile
    /// written under one label and parsed under another would silently lose a
    /// field. The name is deliberately not here — this enum is the prompt.
    enum Field: String, CaseIterable, Sendable {
        case role
        case experience
        case stack

        /// Label used when the profile is written — into the prompt, and into
        /// the answer the model is asked for.
        var label: String {
            switch self {
            case .role: "Роль"
            case .experience: "Опыт"
            case .stack: "Стек"
            }
        }

        /// Labels accepted when reading an answer back.
        ///
        /// English is here because the profile follows the language of the
        /// resume: an English CV makes the model answer `Role:` however plainly
        /// the Russian label was asked for, and dropping the whole field over
        /// that would send the user back to typing it by hand.
        var acceptedLabels: [String] {
            switch self {
            case .role: [label, "Должность", "Role", "Position"]
            case .experience: [label, "Опыт работы", "Experience", "Summary"]
            case .stack: [label, "Стэк", "Технологии", "Навыки", "Stack", "Tech stack", "Skills"]
            }
        }
    }

    subscript(field: Field) -> String {
        get {
            switch field {
            case .role: role
            case .experience: experience
            case .stack: stack
            }
        }
        set {
            switch field {
            case .role: role = newValue
            case .experience: experience = newValue
            case .stack: stack = newValue
            }
        }
    }

    // MARK: - Prompt shape

    /// The block appended to the end of the system prompt (the
    /// `{{resume_context}}` slot in docs/GhostMeet-Prompts.md). Blank fields are
    /// omitted rather than sent as empty labels.
    var promptFragment: String {
        Field.allCases
            .compactMap { field in self[field].trimmedOrNil.map { "\(field.label): \($0)" } }
            .joined(separator: "\n")
    }

    /// Reads a profile back out of labelled text — the inverse of
    /// `promptFragment`, and the only way an imported resume becomes a profile.
    ///
    /// Deliberately forgiving, because the text comes from a model rather than
    /// from a file format: markdown decoration is stripped, English labels are
    /// accepted alongside the Russian ones, lines following a label belong to
    /// it, and anything before the first label is ignored. A model that answered
    /// in prose with no labels at all yields an empty profile — which the caller
    /// reports in words instead of applying silently.
    ///
    /// The `id` is fresh unless the caller keeps its own: an imported profile
    /// usually replaces an existing entry and has to keep that entry's identity.
    static func parsed(from text: String) -> UserProfile {
        var collected: [Slot: [String]] = [:]
        var current: Slot?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = undecorated(String(rawLine))
            if let (slot, value) = labelled(line) {
                current = slot
                collected[slot, default: []].append(value)
            } else if let slot = current {
                collected[slot, default: []].append(line)
            }
        }

        var profile = UserProfile()
        for (slot, lines) in collected {
            let value = meaningful(lines.joined(separator: "\n"))
            if let field = slot.field {
                profile[field] = value
            } else {
                profile.name = value
            }
        }
        return profile
    }

    /// What a parsed answer can fill: the three prompt fields plus the profile's
    /// own name, which the model is allowed to suggest and the user then edits.
    private enum Slot: Hashable, CaseIterable {
        case name
        case field(Field)

        static var allCases: [Slot] { [.name] + Field.allCases.map(Slot.field) }

        var field: Field? {
            if case .field(let field) = self { return field }
            return nil
        }

        var labels: [String] {
            guard let field else { return ["Название", "Профиль", "Name", "Profile", "Title"] }
            return field.acceptedLabels
        }
    }

    /// Splits `Роль: backend-разработчик` into the slot and its value, or
    /// returns nil for an ordinary line.
    private static func labelled(_ line: String) -> (Slot, String)? {
        for slot in Slot.allCases {
            for label in slot.labels {
                guard line.count > label.count,
                      line.lowercased().hasPrefix(label.lowercased()) else { continue }
                let rest = line.dropFirst(label.count).drop { $0 == " " }
                guard rest.first == ":" else { continue }
                return (slot, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Strips the markdown a model adds unasked: headings, bullets, quotes and
    /// bold markers. Without this a perfectly good `**Роль:** …` reads as prose.
    private static func undecorated(_ line: String) -> String {
        line
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
            .drop { "#*->•·—–".contains($0) }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Values a model writes when it means "nothing here". Kept out of the
    /// profile: «Стек: не указано» in a system prompt is worse than no stack
    /// line at all, because the model reads it as a fact about the user.
    private static let placeholders: Set<String> = [
        "", "-", "--", "–", "—", "n/a", "na", "none", "unknown", "not specified", "нет", "нет данных",
        "пусто", "не указано", "не указан", "не указана", "не указаны", "неизвестно",
    ]

    private static func meaningful(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]«»\"'"))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return placeholders.contains(bare) ? "" : trimmed
    }
}

private extension String {
    /// The trimmed string, or `nil` when nothing but whitespace is left.
    nonisolated var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
