//
//  CLIProviderTests.swift
//  GhostMeetTests
//

import Darwin
import Foundation
import Testing
@testable import GhostMeet

/// The CLI transport, driven against stand-ins rather than the real tools: every
/// "tool" here is `/bin/cat` or a throwaway shell script, so nothing depends on
/// `claude` being installed, logged in, or in the mood.
///
/// What is being checked is the three things that make this transport safe to
/// ship: the answer is read while it is being written, cancellation actually
/// kills the process, and a tool that is not installed produces a sentence
/// instead of a crash.
@Suite("Провайдер CLI")
struct CLIProviderTests {

    // MARK: - Промпт и стриминг

    @Test("Промпт уходит инструменту на стандартный вход целиком")
    func promptIsFedToTheToolOnStandardInput() async {
        // `cat` is the honest stand-in: whatever we send it comes back verbatim.
        let provider = CLIProvider(
            name: "Эхо",
            configuration: CLIProvider.Configuration(command: ["/bin/cat"], searchPaths: [])
        )
        let request = fixture()

        let answer = await drainStream(provider.stream(request))

        #expect(answer.error == nil)
        #expect(answer.fragments.joined() == CLIProvider.prompt(for: request))
        #expect(answer.fragments.joined().contains(request.systemPrompt))
        #expect(answer.fragments.joined().contains(request.userPrompt))
    }

    @Test("Ответ читается по мере появления, а не после завершения процесса")
    func answerIsReadWhileItIsBeingWritten() async throws {
        try await withToolDirectory { directory in
            let gate = directory.appendingPathComponent("gate")
            let tool = try script(
                in: directory,
                named: "slow-tool",
                body: """
                /bin/echo ПЕРВЫЙ
                while [ ! -f "\(gate.path)" ]; do /bin/sleep 0.02; done
                /bin/echo ВТОРОЙ
                """
            )
            let provider = CLIProvider(
                name: "Медленный",
                configuration: CLIProvider.Configuration(command: [tool.path], searchPaths: [])
            )
            let received = FragmentCollector()

            let consumer = Task {
                for try await fragment in provider.stream(fixture()) {
                    await received.append(fragment)
                }
            }
            defer { consumer.cancel() }

            #expect(
                await waitUntil { await received.text.contains("ПЕРВЫЙ") },
                "первый кусок обязан дойти до подсказки, пока инструмент ещё работает"
            )
            let beforeTheGateOpened = await received.text
            #expect(
                !beforeTheGateOpened.contains("ВТОРОЙ"),
                "второго куска инструмент ещё не написал"
            )

            FileManager.default.createFile(atPath: gate.path, contents: nil)

            #expect(await waitUntil { await received.text.contains("ВТОРОЙ") })
        }
    }

    @Test("Пустой транскрипт не роняет запуск — на вход уходит заглушка")
    func emptyTranscriptStillProducesAPrompt() {
        let prompt = CLIProvider.prompt(
            for: SuggestionRequest(systemPrompt: "", userPrompt: "  ", screenshot: nil, maxTokens: 512)
        )

        #expect(prompt == "(пусто)")
    }

    @Test("Изображения CLI-инструменты не принимают — говорим об этом честно")
    func capabilitiesAdmitThereIsNoPlaceForAnImage() {
        let provider = CLIProvider(
            name: "Claude CLI",
            configuration: CLIProvider.Configuration(command: ["claude", "-p"], searchPaths: [])
        )

        #expect(!provider.capabilities.acceptsImages)
        #expect(provider.capabilities.streams, "поток здесь настоящий: читаем stdout по мере появления")
    }

    @Test("Русский текст, разорванный между чтениями из трубы, не теряет букв")
    func multibyteTextSplitBetweenReadsSurvives() {
        var text = IncrementalUTF8Text()
        let bytes = Array("Привет".utf8)

        // Пять байт — это две буквы и половина третьей.
        let first = text.append(Data(bytes[0..<5]))
        let second = text.append(Data(bytes[5...]))

        #expect(first == "Пр")
        #expect(first + second == "Привет")
        #expect(!(first + second).contains("\u{FFFD}"))
    }

    // MARK: - Инструмент не установлен

    @Test("Инструмент не установлен — понятная ошибка с именем, а не падение")
    func missingToolBecomesAReadableFailure() async throws {
        try await withToolDirectory { directory in
            let provider = CLIProvider(
                name: "Claude CLI",
                configuration: CLIProvider.Configuration(
                    command: ["ghostmeet-inexistent-tool", "-p"],
                    searchPaths: [directory.path]
                )
            )

            let answer = await drainStream(provider.stream(fixture()))
            let failure = try #require(answer.error as? LLMFailure)

            #expect(answer.fragments.isEmpty)
            #expect(failure.message.contains("ghostmeet-inexistent-tool"))
            #expect(failure.message.contains("Claude CLI"))
        }
    }

    @Test("PATH у приложения беднее терминального — ищем и там, где инструменты правда лежат")
    func searchPathsCoverWhereToolsActuallyLive() {
        // Ровно то, что launchd отдаёт приложению, запущенному из Finder.
        let paths = CLIExecutable.searchPaths(environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])

        #expect(paths.first == "/usr/bin", "PATH приложения идёт первым")
        #expect(paths.contains("/opt/homebrew/bin"))
        #expect(paths.contains("/usr/local/bin"))
        #expect(paths.contains(CLIExecutable.expandingTilde("~/.local/bin")))
        #expect(Set(paths).count == paths.count, "дубликаты каталогов ничего не добавляют")
    }

    @Test("Инструмент, установленный вне PATH, всё равно находится")
    func toolOutsideThePathIsStillFound() async throws {
        try await withToolDirectory { directory in
            let tool = try script(in: directory, named: "kimi", body: "/bin/echo ок")

            #expect(CLIExecutable.locate("kimi", in: [directory.path]) == tool)
            #expect(CLIExecutable.locate("kimi", in: []) == nil)
        }
    }

    @Test("Каталог с именем инструмента за инструмент не принимаем")
    func aDirectoryNamedLikeTheToolIsNotAnExecutable() async throws {
        try await withToolDirectory { directory in
            let trap = directory.appendingPathComponent("codex")
            try FileManager.default.createDirectory(at: trap, withIntermediateDirectories: true)

            #expect(CLIExecutable.locate("codex", in: [directory.path]) == nil)
        }
    }

    // MARK: - Отказ инструмента

    @Test("Инструмент завершился с ошибкой — показываем его собственные слова")
    func toolFailureIsReportedInTheToolsOwnWords() async throws {
        try await withToolDirectory { directory in
            let tool = try script(
                in: directory,
                named: "angry-tool",
                body: """
                /bin/echo "Не выполнен вход в аккаунт" >&2
                exit 3
                """
            )
            let provider = CLIProvider(
                name: "Codex CLI",
                configuration: CLIProvider.Configuration(command: [tool.path], searchPaths: [])
            )

            let failure = try #require(await drainStream(provider.stream(fixture())).error as? LLMFailure)

            #expect(failure.message.contains("Не выполнен вход в аккаунт"))
        }
    }

    @Test("Инструмент промолчал и умер — ошибка всё равно называет код возврата")
    func silentFailureStillSaysSomething() async throws {
        try await withToolDirectory { directory in
            let tool = try script(in: directory, named: "silent-tool", body: "exit 7")
            let provider = CLIProvider(
                name: "Kimi CLI",
                configuration: CLIProvider.Configuration(command: [tool.path], searchPaths: [])
            )

            let failure = try #require(await drainStream(provider.stream(fixture())).error as? LLMFailure)

            #expect(failure.message.contains("Kimi CLI"))
            #expect(failure.message.contains("7"))
        }
    }

    /// Инструмент, убитый сигналом посреди ответа, возвращает 15 или 9 — и до
    /// этой правки половина ответа, которую пользователь читал вслух, исчезала
    /// с экрана: карточка при отказе рисует причину ВМЕСТО текста.
    @Test("Инструмент умер посреди ответа — прочитанное остаётся, причина под ним")
    func aToolDyingMidAnswerKeepsWhatItSaid() async throws {
        try await withToolDirectory { directory in
            let tool = try script(
                in: directory,
                named: "dying-tool",
                body: "printf 'Я бы взял составной индекс по статусу и дате, '\nexit 15"
            )
            let provider = CLIProvider(
                name: "Claude CLI",
                configuration: CLIProvider.Configuration(command: [tool.path], searchPaths: [])
            )

            let answer = await drainStream(provider.stream(fixture()))

            #expect(answer.fragments.joined() == "Я бы взял составной индекс по статусу и дате, ")
            let cutoff = try #require(answer.error as? SuggestionCutoff)
            #expect(cutoff.message.contains("Claude CLI"))
            #expect(answer.error as? LLMFailure == nil, "отказ стёр бы прочитанное с экрана")
        }
    }

    @Test("Инструмент отработал молча и с нулём — сказано, что ответ пуст")
    func aSilentSuccessIsExplained() async throws {
        try await withToolDirectory { directory in
            let tool = try script(in: directory, named: "mute-tool", body: "exit 0")
            let provider = CLIProvider(
                name: "Kimi CLI",
                configuration: CLIProvider.Configuration(command: [tool.path], searchPaths: [])
            )

            #expect(await drainStream(provider.stream(fixture())).error as? SuggestionCutoff == .empty)
        }
    }

    // MARK: - Отмена

    @Test("Новая реплика отменила подсказку — процесс убит, а не оставлен сиротой")
    func cancellationKillsTheProcess() async throws {
        try await withToolDirectory { directory in
            let pidFile = directory.appendingPathComponent("pid")
            let tool = try script(
                in: directory,
                named: "endless-tool",
                body: """
                /bin/echo $$ > "\(pidFile.path)"
                /bin/echo ПОШЛО
                while true; do /bin/sleep 0.05; done
                """
            )
            let provider = CLIProvider(
                name: "Бесконечный",
                configuration: CLIProvider.Configuration(command: [tool.path], searchPaths: [])
            )
            let received = FragmentCollector()

            let consumer = Task {
                for try await fragment in provider.stream(fixture()) {
                    await received.append(fragment)
                }
            }

            #expect(await waitUntil { await received.text.contains("ПОШЛО") })
            let pid = try #require(await waitForPID(in: pidFile))
            #expect(isAlive(pid), "инструмент должен работать до отмены")

            consumer.cancel()

            #expect(
                await waitUntil { !isAlive(pid) },
                "осиротевший процесс дописывает ответ в никуда и тратит подписку"
            )
        }
    }

    // MARK: - Выбор в настройках

    @Test("Фабрика собирает CLI-провайдера по предустановке, без ключа")
    func factoryBuildsTheCLIProvider() throws {
        let provider = try ProviderFactory.make(
            selection: ProviderSelection(presetID: "claude-cli", baseURL: "", model: ""),
            key: { nil }
        )

        #expect(provider is CLIProvider)
        #expect(provider.name == "Claude CLI")
        #expect(!provider.capabilities.acceptsImages)
    }

    @Test("Каждый CLI-инструмент запускается своей командой")
    func everyToolKeepsItsOwnCommand() {
        let commands = ProviderFactory.presets
            .filter { $0.transport == .cli }
            .map(\.command)

        #expect(commands.contains(["claude", "-p"]))
        #expect(commands.allSatisfy { !$0.isEmpty }, "без команды провайдер запускать нечего")
        #expect(
            ProviderFactory.presets.filter { $0.transport == .cli }.allSatisfy { !$0.needsKey },
            "CLI работает на подписке уже залогиненного инструмента"
        )
    }
}

// MARK: - Хелперы

private actor FragmentCollector {
    private(set) var fragments: [String] = []

    var text: String { fragments.joined() }

    func append(_ fragment: String) {
        fragments.append(fragment)
    }
}

/// A throwaway directory to put stand-in "tools" in.
private func withToolDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ghostmeet-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

/// Writes an executable shell script — a stand-in for a real CLI tool.
private func script(in directory: URL, named name: String, body: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func waitForPID(in file: URL) async -> pid_t? {
    _ = await waitUntil { FileManager.default.fileExists(atPath: file.path) }
    guard let text = try? String(contentsOf: file, encoding: .utf8),
          let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return value
}

/// Asks the kernel directly, which is the only answer that settles whether the
/// process was really killed.
private func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

private func fixture() -> SuggestionRequest {
    SuggestionRequest(
        systemPrompt: "Ты — GhostMeet, скрытый real-time copilot.",
        userPrompt: "Недавний разговор:\nThem: расскажите про GCD\n\nСделай то, что нужно мне прямо сейчас.",
        screenshot: nil,
        maxTokens: AssistPrompt.maxTokens
    )
}

/// Reads a stream to its end, keeping both what arrived and how it ended.
private func drainStream(
    _ stream: AsyncThrowingStream<String, any Error>
) async -> (fragments: [String], error: (any Error)?) {
    var fragments: [String] = []
    do {
        for try await fragment in stream { fragments.append(fragment) }
        return (fragments, nil)
    } catch {
        return (fragments, error)
    }
}

/// Waits for something that happens on another task, without sleeping blindly.
///
/// Предел — общий `TestWait.budget`: свои пять секунд этот стенд пережил, но
/// расхождение чисел между стендами уже однажды и было причиной — одно из них
/// просто отставало (см. `TestWait`).
private func waitUntil(
    within timeout: Duration = TestWait.budget,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
