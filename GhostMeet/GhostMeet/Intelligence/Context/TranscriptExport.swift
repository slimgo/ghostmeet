//
//  TranscriptExport.swift
//  GhostMeet
//

import Foundation

/// Builds the file a user gets when they ask to save the call: both channels and
/// the model's answers, in one list, in the order they happened.
///
/// **Pure, and files are somebody else's job.** This type turns values into a
/// string and never touches the disk — the save panel and the write live in the
/// UI layer. That is what lets every rule below be exercised without a
/// filesystem, and it is the only reason the ordering trap in `Entry` is
/// testable at all.
nonisolated enum TranscriptExport {

    // MARK: - Что известно о звонке помимо реплик

    /// The header of the file: what the call was, not what was said in it.
    ///
    /// Every field is optional because every one of them genuinely can be
    /// missing — a call started before a provider was picked, a source
    /// application never chosen — and a caption with an empty value is worse
    /// than no caption: it reads as a fact.
    struct Metadata: Equatable, Sendable {
        var savedAt: Date
        var profile: String?
        var provider: String?
        var source: String?

        init(savedAt: Date, profile: String? = nil, provider: String? = nil, source: String? = nil) {
            self.savedAt = savedAt
            self.profile = profile
            self.provider = provider
            self.source = source
        }
    }

    /// Ties the two clocks of this app together for the length of one export.
    ///
    /// **A turn and a suggestion are stamped on different scales.**
    /// `Turn.timestamp` is `ProcessInfo.systemUptime` — monotonic seconds from an
    /// arbitrary origin, chosen so that the user's clock moving does not reopen
    /// turns that were already closed (see `SessionClock`). `Suggestion.startedAt`
    /// is an ordinary `Date`. Sorting one against the other without a conversion
    /// does not produce a slightly wrong order — it puts every answer either
    /// before or after the whole conversation.
    ///
    /// One pair of readings taken at export time is enough to convert: both
    /// scales advance at the same rate. The one case where the anchor lies is a
    /// machine that slept mid-session, because uptime does not advance while it
    /// does; over a call that is not a case.
    struct Anchor: Equatable, Sendable {
        let uptime: TimeInterval
        let date: Date

        init(uptime: TimeInterval, date: Date) {
            self.uptime = uptime
            self.date = date
        }

        func date(forUptime stamp: TimeInterval) -> Date {
            date.addingTimeInterval(stamp - uptime)
        }
    }

    // MARK: - Одна запись ленты

    /// A line of the file, already on one clock.
    private struct Entry {
        let at: Date
        let title: String
        let body: String
    }

    // MARK: - Сборка

    /// The whole file.
    ///
    /// Leaked turns are dropped and **counted**: the count goes into the header
    /// because dropping them silently would make «протечек не было»
    /// indistinguishable from «фильтр их не увидел», and the second is a real
    /// state of this app — `LeakDedup` needs five matched words before it marks
    /// anything, so a short leak is never marked at all.
    static func markdown(
        turns: [Turn],
        suggestions: [Suggestion],
        metadata: Metadata,
        anchor: Anchor
    ) -> String {
        let kept = turns.filter { !$0.isLeak }
        let dropped = turns.count - kept.count

        let entries = merged(turns: kept, suggestions: suggestions, anchor: anchor)
        let header = header(metadata: metadata, entries: entries, dropped: dropped)

        guard let first = entries.first else {
            return header + "\n\n_Разговор пуст: сохранять нечего._\n"
        }

        let body = entries.map { entry in
            "**\(entry.title)** · \(offset(of: entry.at, from: first.at))\n\(entry.body)"
        }

        return header + "\n\n---\n\n" + body.joined(separator: "\n\n") + "\n"
    }

    /// Both kinds of record on one clock, in the order they happened.
    ///
    /// Sorted here rather than trusted from the caller: the feed and the
    /// transcript are two independent lists, and nothing guarantees that
    /// appending one kept pace with the other.
    private static func merged(
        turns: [Turn],
        suggestions: [Suggestion],
        anchor: Anchor
    ) -> [Entry] {
        let spoken = turns.map { turn in
            Entry(
                at: anchor.date(forUptime: turn.timestamp),
                title: turn.channel == .you ? "You" : "Them",
                body: turn.text.isEmpty ? "_(не распознано)_" : turn.text
            )
        }

        let answered = suggestions.map { suggestion in
            Entry(at: suggestion.startedAt, title: "Подсказка", body: body(of: suggestion))
        }

        return (spoken + answered).sorted { $0.at < $1.at }
    }

    /// The answer as it ended up, with the reason underneath when there is one.
    ///
    /// A cut or superseded answer is kept rather than skipped: half an answer is
    /// what the user actually read out loud, and a file that quietly showed it as
    /// whole would misrepresent the call.
    private static func body(of suggestion: Suggestion) -> String {
        var lines: [String] = []

        if let notice = suggestion.notice {
            lines.append("_\(notice)_")
        }

        switch suggestion.state {
        case .streaming, .complete:
            lines.append(suggestion.text.isEmpty ? "_(пусто)_" : suggestion.text)
        case .superseded:
            lines.append(suggestion.text.isEmpty ? "_(пусто)_" : suggestion.text)
            lines.append("_Ответ перебит следующим нажатием._")
        case .cut(let reason):
            lines.append(suggestion.text.isEmpty ? "_(пусто)_" : suggestion.text)
            lines.append("_Ответ оборван: \(reason)_")
        case .failed(let reason):
            lines.append("_Ответа не было: \(reason)_")
        }

        return lines.joined(separator: "\n\n")
    }

    // MARK: - Шапка

    private static func header(metadata: Metadata, entries: [Entry], dropped: Int) -> String {
        var facts: [String] = []

        if let duration = duration(of: entries) {
            facts.append("Длительность \(humanDuration(duration))")
        }
        if let profile = metadata.profile, !profile.isEmpty {
            facts.append("профиль «\(profile)»")
        }
        if let provider = metadata.provider, !provider.isEmpty {
            facts.append(provider)
        }

        var tail: [String] = []
        if let source = metadata.source, !source.isEmpty {
            tail.append("Источник: \(source)")
        }
        if dropped > 0 {
            tail.append("выброшено как протечка: \(dropped) \(lines(dropped))")
        }

        var header = "# GhostMeet — \(started(metadata: metadata, entries: entries))"
        if !facts.isEmpty { header += "\n\n" + facts.joined(separator: " · ") }
        if !tail.isEmpty { header += (facts.isEmpty ? "\n\n" : "\n") + tail.joined(separator: " · ") }
        return header
    }

    private static func started(metadata: Metadata, entries: [Entry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter.string(from: entries.first?.at ?? metadata.savedAt)
    }

    private static func duration(of entries: [Entry]) -> TimeInterval? {
        guard let first = entries.first, let last = entries.last, last.at > first.at else { return nil }
        return last.at.timeIntervalSince(first.at)
    }

    // MARK: - Время

    /// `мм:сс` from the first record. Relative rather than absolute on purpose:
    /// nobody reading a conversation back needs to know it was 15:42, and
    /// everybody needs to know it was twelve minutes in.
    private static func offset(of moment: Date, from start: Date) -> String {
        let seconds = max(0, Int(moment.timeIntervalSince(start).rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func humanDuration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        guard minutes > 0 else { return "меньше минуты" }
        return "\(minutes) \(minutesWord(minutes))"
    }

    private static func minutesWord(_ count: Int) -> String {
        let tail = count % 100
        if (11...14).contains(tail) { return "минут" }
        switch count % 10 {
        case 1: return "минута"
        case 2, 3, 4: return "минуты"
        default: return "минут"
        }
    }

    private static func lines(_ count: Int) -> String {
        let tail = count % 100
        if (11...14).contains(tail) { return "строк" }
        switch count % 10 {
        case 1: return "строка"
        case 2, 3, 4: return "строки"
        default: return "строк"
        }
    }
}
