//
//  UpdateNoticeView.swift
//  GhostMeet
//

import SwiftUI

/// One quiet line about updating, and the only place updating is ever visible.
///
/// **Not a fourth field in the readiness strip.** That strip answers «чем я
/// вооружён» in one line across 420 points and truncates already; a fourth field
/// would push the profile name off it to state something that is usually not
/// worth stating at all. This appears only when there is something to say, and
/// takes no room the rest of the time — the same bargain `routeNotice` strikes
/// one line below.
///
/// **It is shown before the call and not during it.** The caller hides it once
/// listening starts: a new version is news, not a diagnosis, and news hanging
/// over the suggestion feed for an hour is the nagging kind of honesty that gets
/// ignored. Nothing about it is urgent — the build in hand keeps working.
///
/// **Everything updating has to say, it says here.** Sparkle's own windows are
/// turned off (`OverlayUpdateDriver`), because a window of somebody else's on top
/// of a shared screen is precisely the failure this app is built to avoid
/// (ADR-0004). So the download, the failure and the «сейчас перезапущусь» all
/// arrive on this line.
struct UpdateNoticeView: View {

    let phase: UpdatePhase

    /// «Обновить» — downloads, verifies and replaces the app.
    let install: () -> Void

    /// Puts the line away for this launch — see `UpdateStatus.dismiss()`.
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(message)
            } icon: {
                Image(systemName: icon)
            }

            if case .available = phase {
                Button("обновить", action: install)
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }

            Spacer(minLength: 0)

            if isDismissable {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Скрыть до следующего запуска")
                .accessibilityLabel("Скрыть сообщение об обновлении")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// What the line says, in the words the user needs rather than the words the
    /// framework used.
    private var message: String {
        switch phase {
        case .idle:
            ""
        case .checking:
            "Проверяю, есть ли новая версия…"
        case .available(let update):
            "Вышла версия \(update.version)"
        case .downloading(let fraction):
            fraction.map { "Загружаю обновление — \(Int($0 * 100))%" } ?? "Загружаю обновление…"
        case .preparing:
            "Готовлю обновление…"
        case .installing:
            "Ставлю обновление — приложение сейчас перезапустится"
        case .upToDate:
            "Установлена последняя версия"
        case .failed(let reason):
            "Обновиться не вышло: \(reason)"
        }
    }

    private var icon: String {
        switch phase {
        case .failed: "exclamationmark.triangle"
        case .upToDate: "checkmark.circle"
        case .installing, .preparing: "gearshape"
        default: "arrow.down.circle"
        }
    }

    /// Progress cannot be put away, because putting it away would leave the app
    /// replacing itself with nothing on screen saying so.
    private var isDismissable: Bool {
        switch phase {
        case .available, .upToDate, .failed: true
        case .idle, .checking, .downloading, .preparing, .installing: false
        }
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }
}

#Preview("Вышла версия") {
    UpdateNoticeView(
        phase: .available(OfferedUpdate(version: "0.4.0", notes: nil)),
        install: {},
        dismiss: {}
    )
    .frame(width: 420)
}

#Preview("Загрузка") {
    UpdateNoticeView(phase: .downloading(fraction: 0.42), install: {}, dismiss: {})
        .frame(width: 420)
}

#Preview("Не вышло") {
    UpdateNoticeView(
        phase: .failed("Обновление отложено: идёт прослушивание"),
        install: {},
        dismiss: {}
    )
    .frame(width: 420)
}
