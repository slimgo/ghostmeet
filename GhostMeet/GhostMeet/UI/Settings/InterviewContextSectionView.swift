//
//  InterviewContextSectionView.swift
//  GhostMeet
//

import SwiftUI

/// The `Контекст собеседования` section: four things the user prepared for the
/// call they are about to take.
///
/// Drawn directly under `Профиль` and worded against it on purpose. The two look
/// alike — text fields with hints — and the only thing keeping the user from
/// typing «почему эта компания» into the profile is the sentence at the top of
/// this section saying which of the two survives the next interview.
struct InterviewContextSectionView: View {

    @Bindable var store: SettingsStore

    var body: some View {
        Section("Контекст собеседования") {
            Text("Это про конкретный звонок, а не про вас: другая компания — другой контекст. Профиль выше остаётся тем же, сколько бы собеседований вы ни прошли.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Built from the model's own list of fields, so a field added there
            // cannot quietly end up with storage and no way to fill it in.
            ForEach(InterviewContext.Field.allCases, id: \.self) { field in
                SettingsParagraphRow(field.screenLabel) {
                    TextField(placeholder(for: field), text: binding(for: field), axis: .vertical)
                        .lineLimit(lineLimit(for: field))
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("Пустое поле не попадает в подсказку вовсе — заполняйте только то, что действительно заготовили.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Всё написанное здесь уходит выбранному провайдеру вместе с профилем. Название компании и суммы — тоже: не пишите сюда того, чего не отправили бы наружу.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Очистить перед следующим собеседованием") {
                    store.clearInterviewContext()
                }
                .disabled(store.interviewContext.isEmpty)
                Spacer()
            }

            Text("Очистка контекста разговора — та, что на горячей клавише, — стирает транскрипт звонка и эти поля не трогает. Здесь очищаете вы сами, когда идёте в следующую компанию.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for field: InterviewContext.Field) -> Binding<String> {
        Binding(
            get: { store.interviewContext[field] },
            set: { store.interviewContext[field] = $0 }
        )
    }

    /// The hint that does the work the data type deliberately does not: the
    /// stories field is free text, and this is where its four steps live.
    private func placeholder(for field: InterviewContext.Field) -> String {
        switch field {
        case .stories:
            "По одной истории на абзац: ситуация — задача — что сделал — результат в цифрах. Например: платежи падали по ночам → нашёл дедлок в очереди → переписал на идемпотентные ретраи → отказы с 3% до 0.1%"
        case .motivation:
            "Например: продукт про платежи, знаком по прошлой работе; команда 12 человек; интересна миграция на Go"
        case .compensation:
            "Например: 350–400 тысяч на руки, готов обсуждать при сильном опционе"
        case .questions:
            "Например: как устроен онбординг; кто принимает решение по архитектуре; почему открыта вакансия"
        }
    }

    private func lineLimit(for field: InterviewContext.Field) -> ClosedRange<Int> {
        switch field {
        case .stories: 3...12
        case .motivation, .questions: 2...6
        case .compensation: 1...3
        }
    }
}

#Preview {
    Form {
        InterviewContextSectionView(
            store: SettingsStore(
                defaults: UserDefaults(suiteName: "GhostMeetInterviewContextPreview") ?? .standard,
                secrets: InMemorySecretStore()
            )
        )
    }
    .formStyle(.grouped)
}
