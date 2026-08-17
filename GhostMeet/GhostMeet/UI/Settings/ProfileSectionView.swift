//
//  ProfileSectionView.swift
//  GhostMeet
//

import SwiftUI
import UniformTypeIdentifiers

/// The `Профиль` section of the settings screen: which profile is in force,
/// what it says, and the second way of filling it in — a resume.
///
/// Both ways lead to the same three fields. The imported profile is not shown
/// somewhere else or kept separately; it lands in the very fields the user could
/// have typed, in the profile they had selected, and is editable before anything
/// is saved.
struct ProfileSectionView: View {

    @Bindable var store: SettingsStore

    /// Lives with the screen, not with the store: an import in progress is not
    /// a setting, and abandoning the window must leave nothing behind.
    @State private var resumeImport = ResumeImport()

    @State private var isChoosingResume = false

    var body: some View {
        Section("Профиль") {
            profilePicker
            profileFields
            Text("Профиль относится к вам, а не к звонку: очистка контекста разговора его не стирает. В подсказки уходит выбранный профиль — тот, что стоит в списке выше.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            resumeImportControls
        }
        .sheet(isPresented: isReviewing) {
            ResumeReviewSheet(importer: resumeImport, store: store)
        }
    }

    // MARK: - Выбор профиля

    /// Several resumes mean several profiles: a team lead and a full-stack
    /// senior are different people on paper, and answering an interview from the
    /// wrong one is precisely the failure the profile exists to prevent.
    @ViewBuilder
    private var profilePicker: some View {
        SettingsRow("Активный профиль") {
            Picker("Активный профиль", selection: $store.selectedProfileID) {
                ForEach(store.profiles) { profile in
                    Text(profile.displayName).tag(profile.id)
                }
            }
        }

        HStack {
            Button("Новый профиль") { store.addProfile(named: "Новый профиль") }
            Button("Удалить", role: .destructive) { store.removeProfile(store.selectedProfileID) }
                .disabled(store.profiles.count < 2)
            Spacer()
            Text("Профилей: \(store.profiles.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var profileFields: some View {
        SettingsRow("Название") {
            TextField("Например: тимлид", text: $store.profile.name)
                .textFieldStyle(.roundedBorder)
        }
        SettingsRow("Роль") {
            TextField("Например: backend-разработчик", text: $store.profile.role)
                .textFieldStyle(.roundedBorder)
        }
        SettingsParagraphRow("Опыт") {
            TextField(
                "Например: 6 лет, финтех и высоконагруженные сервисы",
                text: $store.profile.experience,
                axis: .vertical
            )
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
        }
        SettingsParagraphRow("Стек") {
            TextField(
                "Например: Go, PostgreSQL, Kubernetes",
                text: $store.profile.stack,
                axis: .vertical
            )
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Резюме

    /// The second way to fill the fields in — and the warning that goes with it.
    ///
    /// The warning is above the button and not in the sheet behind it: by the
    /// time the file has been read the text is already on its way, and a notice
    /// shown then would be an apology rather than a choice. It names the
    /// provider outright, because "your data goes to the provider" means
    /// nothing to someone who has forgotten which one is selected.
    @ViewBuilder
    private var resumeImportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("Загрузить резюме…") { isChoosingResume = true }
                    .disabled(resumeImport.phase.isBusy)
                if resumeImport.phase.isBusy {
                    ProgressView().controlSize(.small)
                    Text(resumeImport.phase.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Label(store.resumePrivacyNote, systemImage: privacyIcon)
                .font(.footnote)
                .foregroundStyle(privacyColor)

            // Advice, not just a warning. Saying "this leaves your machine" and
            // stopping there leaves the user with nothing to do about it; the
            // fix costs a minute and removes the exposure entirely. The profile
            // needs the experience, never the name.
            Label(
                """
                Перед загрузкой уберите из резюме личные данные: имя, телефон, почту, ссылки на профили, \
                названия компаний, если они под NDA. Для профиля важен опыт, а не то, как вас зовут, — \
                обезличенное резюме даст ровно тот же результат.
                """,
                systemImage: "person.crop.circle.badge.xmark"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Text("Файл никуда не сохраняется: из него берётся только текст, он уходит одним запросом, и в приложении остаётся лишь профиль, который вы утвердите. Загружается в выбранный профиль — «\(store.profile.displayName)».")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Форматы: .txt, .md и .pdf с текстовым слоем. Сканированное резюме — это картинка, из неё текст не берётся.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Inside the window and nowhere else: a system banner would be
            // drawn on top of a shared screen (ADR-0004).
            if case .failed(let message) = resumeImport.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .fileImporter(
            isPresented: $isChoosingResume,
            allowedContentTypes: Self.resumeContentTypes
        ) { result in
            switch result {
            case .success(let url): resumeImport.start(url: url, in: store)
            case .failure(let error): resumeImport.report("Файл не выбран: \(error.localizedDescription).")
            }
        }
    }

    private var privacyIcon: String {
        store.providerDestination == .localMachine ? "checkmark.shield" : "exclamationmark.triangle"
    }

    private var privacyColor: Color {
        store.providerDestination == .localMachine ? .secondary : .orange
    }

    private static var resumeContentTypes: [UTType] {
        [.plainText, .pdf] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    }

    /// The sheet is up exactly while there is something to review; dismissing it
    /// any way at all is a refusal, and refusing throws the draft away.
    private var isReviewing: Binding<Bool> {
        Binding(
            get: { resumeImport.phase == .review },
            set: { if !$0 { resumeImport.cancel() } }
        )
    }
}

/// What the model proposed, before it becomes the profile.
///
/// The same four fields as the section behind it, on purpose: this is not a
/// preview of a different kind of profile, it is the profile, filled in by
/// somebody else and open for correction.
private struct ResumeReviewSheet: View {

    @Bindable var importer: ResumeImport
    let store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Профиль из резюме")
                .font(.headline)

            Text("Модель предложила — проверьте и поправьте. Пока вы не нажали «Применить», профиль не изменился.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let notice = importer.notice {
                Label(notice, systemImage: "scissors")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Form {
                SettingsRow("Название") {
                    TextField("Название профиля", text: $importer.draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsRow("Роль") {
                    TextField("Роль", text: $importer.draft.role)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsParagraphRow("Опыт") {
                    TextField("Опыт", text: $importer.draft.experience, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsParagraphRow("Стек") {
                    TextField("Стек", text: $importer.draft.stack, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("Сам файл резюме нигде не сохранён.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отменить", role: .cancel) { importer.cancel() }
                Button("Применить") { importer.apply(to: store) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importer.draft.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
    }
}

#Preview {
    Form {
        ProfileSectionView(
            store: SettingsStore(
                defaults: UserDefaults(suiteName: "GhostMeetProfilePreview") ?? .standard,
                secrets: InMemorySecretStore()
            )
        )
    }
    .formStyle(.grouped)
}
