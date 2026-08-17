//
//  InterviewContext.swift
//  GhostMeet
//

import Foundation

/// What the user prepared for **one particular interview**: the stories they
/// mean to tell, why this company, what they expect to be paid, what they want
/// to ask back.
///
/// **This sits beside `UserProfile`, not inside it, and the difference is the
/// whole point.** A profile is about the person and outlives calls — «Тимлид»
/// says the same thing in March and in June. This is about the call: the same
/// team-lead profile goes to three companies, and «почему именно вы» has three
/// different answers while the experience behind them does not change once.
/// Folding these fields into the profile would force a copy of the whole
/// profile per company, and then an updated stack would have to be typed three
/// times — which is exactly the failure `ProfileLibrary` exists to prevent,
/// reintroduced from the other end. So: several profiles, one interview
/// context, and the two are edited independently.
///
/// It is nonetheless *user*-scoped storage rather than session state, for a
/// blunt reason: it is typed in before the call, and clearing the conversation
/// mid-interview must not delete something the user spent ten minutes writing.
/// Clearing it is a separate, deliberate action — see
/// `SettingsStore.clearInterviewContext()`.
///
/// Four fields and not fifteen. A fifteen-line questionnaire is one nobody
/// fills in, and an empty questionnaire helps the model less than four fields
/// that actually got typed.
nonisolated struct InterviewContext: Codable, Equatable, Sendable {

    /// Cases from the user's own practice, prepared ahead of time — the
    /// «расскажите случай, когда…» question, which is asked at nearly every
    /// interview and answered badly on the spot.
    ///
    /// Free text and not a list of structured stories. A schema of four
    /// sub-fields times N entries is a form that gets abandoned halfway; the
    /// model does not need our structure, it needs the facts, and it reads
    /// prose perfectly well. The situation-task-action-result shape survives as
    /// wording — in the field's own label and in the hint beside it — so what
    /// the user types is still structured, just not by a data type.
    var stories: String

    /// Why this company, this team, this vacancy — plus whatever is known about
    /// them. The one field that is guaranteed to be wrong at the next
    /// interview, which is the reason this type exists.
    var motivation: String

    /// What the user expects to be paid, in their own words: a range, a
    /// currency, a "not below". Never invented by the model — a number made up
    /// during a call is a number that cannot be walked back.
    var compensation: String

    /// What the user wants to ask the employer. Asked at the end, when the
    /// candidate is tired and remembers nothing.
    var questions: String

    /// A context nothing has been typed into yet.
    static let empty = InterviewContext()

    init(
        stories: String = "",
        motivation: String = "",
        compensation: String = "",
        questions: String = ""
    ) {
        self.stories = stories
        self.motivation = motivation
        self.compensation = compensation
        self.questions = questions
    }

    /// Whether there is nothing here a model could use. Whitespace does not
    /// count as content: a field holding a stray newline must not put an empty
    /// heading into the prompt.
    var isEmpty: Bool {
        Field.allCases.allSatisfy { self[$0].trimmedOrNil == nil }
    }

    // MARK: - Persistence

    /// Decoded field by field with fallbacks, for the same reason `UserProfile`
    /// is: preferences written by a build that had three of these fields must
    /// not lose the three because the fourth is missing. A whole context lost to
    /// a decoding error would be discovered ten minutes before an interview.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stories = try container.decodeIfPresent(String.self, forKey: .stories) ?? ""
        motivation = try container.decodeIfPresent(String.self, forKey: .motivation) ?? ""
        compensation = try container.decodeIfPresent(String.self, forKey: .compensation) ?? ""
        questions = try container.decodeIfPresent(String.self, forKey: .questions) ?? ""
    }

    // MARK: - Fields

    /// The four fields, in the order they are written into a prompt.
    ///
    /// An enum rather than four literals scattered about, exactly as in
    /// `UserProfile.Field`: the labels are prompt wording, the same wording is
    /// reproduced in `docs/GhostMeet-Prompts.md`, and the settings screen builds
    /// its editors from this list — so a fifth field cannot reach storage
    /// without reaching the screen.
    enum Field: String, CaseIterable, Sendable {
        case stories
        case motivation
        case compensation
        case questions

        /// Подпись, под которой поле уходит **в промпт**.
        ///
        /// Не переводится, и это не недосмотр. Промпт целиком русский и сверяется
        /// дословно с `docs/GhostMeet-Prompts.md`; английский интерфейс, который
        /// начал бы слать модели английские подписи, тихо изменил бы промпт — а
        /// расхождение кода с документом ловится тестом только на русской машине.
        /// Языку интерфейса тут делать нечего: он про окно, а не про запрос.
        var label: String {
            switch self {
            case .stories: "Истории из практики"
            case .motivation: "Почему эта компания"
            case .compensation: "Ожидания по деньгам"
            case .questions: "Вопросы к работодателю"
            }
        }

        /// Подпись **на экране**, на языке интерфейса.
        ///
        /// Отдельно от `label` по причине выше. Ценой этому — на английском окне
        /// подпись поля и подпись в промпте перестают совпадать буквально; они
        /// продолжают значить одно и то же, а обещание «пользователь видит, что
        /// сказали модели» держится смыслом, а не побуквенно.
        var screenLabel: String {
            switch self {
            case .stories: String(localized: "Истории из практики")
            case .motivation: String(localized: "Почему эта компания")
            case .compensation: String(localized: "Ожидания по деньгам")
            case .questions: String(localized: "Вопросы к работодателю")
            }
        }
    }

    subscript(field: Field) -> String {
        get {
            switch field {
            case .stories: stories
            case .motivation: motivation
            case .compensation: compensation
            case .questions: questions
            }
        }
        set {
            switch field {
            case .stories: stories = newValue
            case .motivation: motivation = newValue
            case .compensation: compensation = newValue
            case .questions: questions = newValue
            }
        }
    }

    // MARK: - Prompt shape

    /// The block that goes into the system prompt beside the profile — never
    /// instead of it. Empty when nothing has been filled in, so the caller can
    /// leave the whole thing out.
    ///
    /// Blank fields are omitted entirely rather than written as an empty label.
    /// «Ожидания по деньгам:» with nothing after it is not silence — the model
    /// reads it as a statement that the user has no expectations, and answers
    /// the salary question on that basis.
    ///
    /// Written as `Подпись:` on its own line with the value under it, unlike the
    /// profile's inline `Подпись: значение`. These values are paragraphs — three
    /// stories in four steps each — and a paragraph starting after a colon on
    /// the same line is where a model loses track of where one field ends.
    var promptFragment: String {
        Field.allCases
            .compactMap { field in self[field].trimmedOrNil.map { "\(field.label):\n\($0)" } }
            .joined(separator: "\n\n")
    }
}

private extension String {
    /// The trimmed string, or `nil` when nothing but whitespace is left.
    nonisolated var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
