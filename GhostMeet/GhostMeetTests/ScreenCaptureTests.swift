//
//  ScreenCaptureTests.swift
//  GhostMeetTests
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GhostMeet

/// What the model is shown of the screen, and what happens when the screen
/// cannot be shown at all.
///
/// The screenshot is attached to *every* request and is taken at the moment the
/// user presses (ADR-0008), so the interesting cases are the ones where that rule
/// meets something: a backend that cannot take an image, a capture that failed, a
/// Retina display whose frame is too big to send.
@Suite("Снимок экрана и текст с него")
@MainActor
struct ScreenCaptureTests {

    // MARK: - Что уходит в запрос

    @Test("Провайдер принимает картинки — снимок и текст с экрана уходят оба")
    func multimodalProviderGetsBothHalves() async {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        let call = ScreenCall(
            capabilities: .multimodal,
            screen: ScreenContext(image: png, text: "func reverse(_ list: [Int]) -> [Int]")
        )

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        let request = call.provider.requests.first
        #expect(request?.screenshot == png, "снимок обязан дойти до модели, которая его понимает")
        #expect(request?.userPrompt.contains("func reverse(_ list: [Int]) -> [Int]") == true)
        #expect(request?.userPrompt.contains(BriefPrompt.screenTextHeading) == true)
    }

    @Test("Провайдер картинок не принимает — снимка нет, а текст с экрана всё равно уходит")
    func textOnlyProviderGetsTextWithoutTheImage() async {
        let call = ScreenCall(
            capabilities: .textOnly,
            screen: ScreenContext(image: Data([0x89, 0x50]), text: "SELECT * FROM orders")
        )

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        let request = call.provider.requests.first
        #expect(request?.screenshot == nil, "картинка текстовому провайдеру — это провалившийся запрос")
        #expect(
            request?.userPrompt.contains("SELECT * FROM orders") == true,
            "слова с экрана — единственное, что такой провайдер вообще узнает об экране"
        )
    }

    @Test("Экран пустой — блока про экран в промпте нет вовсе")
    func noScreenTextMeansNoScreenBlock() async {
        let call = ScreenCall(capabilities: .multimodal, screen: .none)

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        let prompt = call.provider.requests.first?.userPrompt ?? ""
        #expect(!prompt.contains(BriefPrompt.screenTextHeading), "пустой заголовок читается как «экран чист»")
        #expect(prompt.hasSuffix(BriefPrompt.askOpening) || prompt.hasSuffix(BriefPrompt.askContinuing))
    }

    // MARK: - Сбой захвата

    @Test("Экран снять не удалось — подсказка всё равно уходит, без снимка")
    func captureFailureDoesNotCancelTheSuggestion() async {
        let call = ScreenCall(
            capabilities: .multimodal,
            screen: .failed("Нет разрешения на запись экрана"),
            answers: ["Отвечу ", "по разговору."]
        )

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.count == 1, "сбой захвата экрана не отменяет подсказку")
        #expect(call.engine.suggestions.first?.state == .complete)
        #expect(call.engine.suggestions.first?.text == "Отвечу по разговору.")
        #expect(call.provider.requests.count == 1)
        #expect(call.provider.requests.first?.screenshot == nil)
    }

    @Test("Причина сбоя видна в окне, а не только в логе")
    func captureFailureReachesTheWindow() async {
        let call = ScreenCall(
            capabilities: .multimodal,
            screen: .failed("Нет разрешения на запись экрана")
        )

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.engine.lastError == "Нет разрешения на запись экрана")
    }

    @Test("Захват заработал снова — сообщение о сбое с экрана уходит")
    func aWorkingCaptureClearsTheMessage() async {
        let capturer = ScreenCapturerStub(.failed("Не удалось снять экран"))
        let call = ScreenCall(capabilities: .multimodal, capturer: capturer)

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()
        #expect(call.engine.lastError != nil)

        capturer.result = ScreenContext(image: Data([0x89]), text: "готово")
        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.engine.lastError == nil, "старая жалоба не должна висеть до конца звонка")
    }

    // MARK: - Задержка

    @Test("Снимок начинается сразу по нажатию, не дожидаясь распознавания реплики")
    func screenIsGrabbedBesideRecognition() async {
        // Распознавание держится до отмашки: если снимок ждёт его конца, к этому
        // моменту захват ещё не начался бы.
        let recognizer = HeldRecognizer(reply: "какой у вас стек")
        let capturer = ScreenCapturerStub(ScreenContext(text: "main.swift"))
        let call = ScreenCall(capabilities: .multimodal, recognizer: recognizer, capturer: capturer)

        call.says(.them)
        call.engine.suggestBriefly()
        #expect(
            await capturer.startedCapturing(within: TestWait.budget),
            "захват экрана обязан идти параллельно распознаванию, а не после него"
        )

        await recognizer.release()
        await call.engine.waitForSuggestion()
        #expect(call.provider.requests.first?.userPrompt.contains("main.swift") == true)
    }

    // MARK: - Размер картинки

    @Test("Кадр Retina-дисплея уменьшается перед отправкой")
    func retinaFrameIsScaledDown() throws {
        let frame = try #require(Self.image(width: 3456, height: 2234))

        let png = try #require(ScreenImage.png(from: frame))
        let size = try #require(Self.pixelSize(ofPNG: png))

        #expect(max(size.width, size.height) == ScreenImage.maxDimension)
        #expect(size.width == 1280 && size.height == 827, "пропорции кадра должны сохраниться")
        #expect(png.count < 2_000_000, "мегабайты в каждом запросе — это задержка и деньги")
    }

    @Test("Маленький кадр не растягивается: лишние байты без единого лишнего пикселя")
    func smallFrameIsLeftAlone() throws {
        let frame = try #require(Self.image(width: 640, height: 400))

        let png = try #require(ScreenImage.png(from: frame))
        let size = try #require(Self.pixelSize(ofPNG: png))

        #expect(size.width == 640 && size.height == 400)
    }

    @Test("Уменьшение считается по длинной стороне, какой бы она ни была")
    func theLongEdgeIsWhatIsLimited() {
        let tall = ScreenImage.fittedSize(width: 1000, height: 4000, within: 1000)
        #expect(tall.width == 250 && tall.height == 1000, "вертикальный экран ограничивается по высоте")

        let wide = ScreenImage.fittedSize(width: 4000, height: 1000, within: 1000)
        #expect(wide.width == 1000 && wide.height == 250)

        let small = ScreenImage.fittedSize(width: 800, height: 600, within: 1000)
        #expect(small.width == 800 && small.height == 600)
    }

    @Test("Текст с экрана обрезается: экран документации — это не вопрос")
    func screenTextIsBounded() {
        #expect(ScreenTextRecognizer.maxCharacters > 0)
        #expect(ScreenTextRecognizer.maxCharacters <= 20_000)
    }

    // MARK: - Живая проверка

    /// Проверка на живой машине: своё окно в снимок не попадает.
    ///
    /// Не в общем прогоне, потому что требует экрана, выданного разрешения на
    /// запись и пары секунд. Переменная окружения перед `xcodebuild` **не доходит
    /// до хоста с 0.5.1** (`shouldUseLaunchSchemeArgsEnv = NO` в схеме), и с тех пор
    /// этот тест молча пропускался. Запускать так — см. `LiveTestGate`:
    ///
    /// ```
    /// touch .build/live-tests && xcodebuild ... test \
    ///   -only-testing:GhostMeetTests/ScreenCaptureTests/overlayStaysOutOfTheScreenshot
    /// ```
    @Test(
        "Живьём: окно с sharingType = .none в снимок не попадает",
        .enabled(if: LiveTestGate.isEnabled("GHOSTMEET_LIVE_SCREEN"))
    )
    func overlayStaysOutOfTheScreenshot() async throws {
        let hidden = Self.marker(NSWindow.SharingType.none, text: "GHOSTMEETHIDDEN")
        let visible = Self.marker(.readOnly, text: "GHOSTMEETVISIBLE")
        defer {
            hidden.close()
            visible.close()
        }
        // Окну нужно попасть в композицию оконного сервера до того, как его снимут.
        try await Task.sleep(for: .milliseconds(700))

        let started = ContinuousClock.now
        let screen = await ScreenCaptureService().capture()
        let elapsed = ContinuousClock.now - started

        print("ЖИВАЯ ПРОВЕРКА: снимок+OCR за \(elapsed), кб=\((screen.image?.count ?? 0) / 1024)")
        print("ЖИВАЯ ПРОВЕРКА: символов OCR = \(screen.text.count)")
        // Что вообще было на экране в момент снимка, включая настоящее окно
        // приложения: без этого списка «маркера нет» ничего не доказывает.
        for window in NSApp.windows where window.isVisible {
            print("ЖИВАЯ ПРОВЕРКА ОКНО: \(type(of: window)) sharingType=\(window.sharingType.rawValue) \(window.frame)")
        }

        #expect(screen.failure == nil, "экран должен был сняться: \(screen.failure ?? "")")
        let text = screen.text.replacingOccurrences(of: " ", with: "")
        #expect(text.contains("GHOSTMEETVISIBLE"), "контрольное окно обязано читаться — иначе проверка ни о чём")
        #expect(!text.contains("GHOSTMEETHIDDEN"), "окно с sharingType = .none попало в снимок")
    }

    /// Панель, собранная ровно так, как собирается окно-оверлей приложения, с
    /// одним словом крупным шрифтом внутри — чтобы Vision его точно прочла.
    ///
    /// Единственное, чем два таких окна в проверке отличаются друг от друга, —
    /// `sharingType`. Иначе сравнивать было бы нечего.
    private static func marker(_ sharing: NSWindow.SharingType, text: String) -> NSWindow {
        var configuration = OverlayWindowConfiguration.overlay
        configuration.sharingType = sharing

        let panel = NSPanel(
            contentRect: NSRect(x: 140, y: 160, width: 900, height: 200),
            styleMask: configuration.styleMask,
            backing: .buffered,
            defer: false
        )
        configuration.apply(to: panel)

        let backing = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        backing.wantsLayer = true
        backing.layer?.backgroundColor = NSColor.white.cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 64, weight: .bold)
        label.textColor = .black
        label.frame = NSRect(x: 24, y: 60, width: 852, height: 90)
        backing.addSubview(label)

        panel.contentView = backing
        panel.orderFrontRegardless()
        return panel
    }

    // MARK: - Хелперы

    private static func image(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func pixelSize(ofPNG data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

// MARK: - Обстановка звонка

/// A call whose screen is whatever the test says it is.
///
/// Same shape as `SuggestionCall` in the trigger suite, with the two things this
/// ticket is about wired in: what the capturer returns, and what the provider is
/// willing to accept.
@MainActor
private struct ScreenCall {
    let engine: SessionEngine
    let provider: ScreenStubProvider

    private let clock: ManualClock
    private let frameLength: TimeInterval = 0.1

    init(
        capabilities: ProviderCapabilities,
        screen: ScreenContext = .none,
        answers: [String] = ["готово"],
        recognizer: SpeechRecognizer = RecognizerSpy(reply: "какой у вас стек"),
        capturer: (any ScreenCapturer)? = nil
    ) {
        let clock = ManualClock()
        self.clock = clock
        self.provider = ScreenStubProvider(capabilities: capabilities, answers: answers)
        self.engine = SessionEngine(
            recognizer: recognizer,
            provider: provider,
            composer: PromptComposer(profile: { .empty }),
            capturer: capturer ?? ScreenCapturerStub(screen),
            clock: clock
        )
    }

    func says(_ channel: Channel, for seconds: TimeInterval = 1.2) {
        feed(seconds: seconds) { AudioFrames.speech(channel: channel, duration: frameLength) }
        feed(seconds: TurnSegmentationConfig.default.pauseThreshold + 0.2) { AudioFrames.silence(channel: channel, duration: frameLength) }
    }

    private func feed(seconds: TimeInterval, frame: () -> AudioFrame) {
        let frames = Int((seconds / frameLength).rounded())
        for _ in 0..<frames {
            clock.advance(by: frameLength)
            engine.ingest(frame())
        }
    }
}

/// A screen that shows whatever the test put in it, and remembers being asked.
private final class ScreenCapturerStub: ScreenCapturer, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: ScreenContext
    private var asked = false

    init(_ result: ScreenContext) {
        self.stored = result
    }

    var result: ScreenContext {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func capture() async -> ScreenContext {
        lock.withLock {
            asked = true
            return stored
        }
    }

    /// Whether the engine has already asked for the screen.
    func startedCapturing(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lock.withLock({ asked }) { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

/// Recognition that does not finish until the test lets it.
private actor HeldRecognizer: SpeechRecognizer {

    private let reply: String
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(reply: String) {
        self.reply = reply
    }

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        if !released {
            await withCheckedContinuation { waiting.append($0) }
        }
        return reply
    }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

/// A model that answers from a script and declares what it accepts.
private final class ScreenStubProvider: LLMProvider, @unchecked Sendable {

    let name = "Заглушка"
    let capabilities: ProviderCapabilities

    private let lock = NSLock()
    private let answers: [String]
    private var recorded: [SuggestionRequest] = []

    init(capabilities: ProviderCapabilities, answers: [String]) {
        self.capabilities = capabilities
        self.answers = answers
    }

    var requests: [SuggestionRequest] {
        lock.withLock { recorded }
    }

    func stream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, any Error> {
        lock.withLock { recorded.append(request) }
        let answers = answers
        return AsyncThrowingStream { continuation in
            for answer in answers { continuation.yield(answer) }
            continuation.finish()
        }
    }
}
