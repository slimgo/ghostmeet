//
//  AudioRoute.swift
//  GhostMeet
//

import Foundation

/// One end of the audio route, as Core Audio describes it.
///
/// Three properties and no more, because these are the three that were actually
/// probed on the target machine — the name the user reads in «Системных
/// настройках», the transport, and the data source. Anything else (model UID,
/// stream format, channel count) turned out to say nothing about where the sound
/// physically goes.
nonisolated struct AudioEndpoint: Equatable, Sendable {

    /// What the device is called in the system UI. Shown to the user verbatim:
    /// «HUAWEI FreeBuds 5i» answers the question the classifier cannot.
    let name: String

    /// The four-character transport code — `bltn`, `blue`, `usb`, `virt`, `grup`.
    /// Trailing spaces of the four-character code are stripped.
    let transport: String

    /// The four-character data source code (`ispk`, `imic`, `hdpn`), or `nil`
    /// when the device has no such property.
    ///
    /// «No such property» and «blanks» are the same thing here, and that is
    /// measured rather than defensive: of the four output devices on the bench,
    /// BlackHole and the aggregate have no `dataSource` at all, while Microsoft
    /// Teams Audio and Iriun report one made of four spaces. Treating the blank
    /// as a value would give those devices a data source that matches nothing and
    /// looks, in a log, like a real answer.
    let dataSource: String?

    init(name: String, transport: String, dataSource: String?) {
        self.name = name
        self.transport = Self.normalized(transport) ?? ""
        self.dataSource = Self.normalized(dataSource)
    }

    private static func normalized(_ code: String?) -> String? {
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - The three things that can be said for certain

    /// The MacBook's own speakers: measured on the bench as `bltn` + `ispk`.
    var isBuiltInSpeakers: Bool {
        transport == AudioTransport.builtIn && dataSource == AudioDataSource.internalSpeaker
    }

    /// The MacBook's own microphone: measured on the bench as `bltn` + `imic`.
    var isBuiltInMicrophone: Bool {
        transport == AudioTransport.builtIn && dataSource == AudioDataSource.internalMicrophone
    }

    /// Whether this is the same physical device as `other`.
    ///
    /// Compared by the name the system shows, because that is what this type
    /// carries and what the user reads — a headset appears as one name on both
    /// ends («HUAWEI FreeBuds 5i»), while the Mac's own ends are two different
    /// names («Микрофон MacBook Air» against «Динамики MacBook Air») and cannot
    /// collide by accident. Transport has to agree too: two devices of the same
    /// name on different buses are not one device.
    func isSameDevice(as other: AudioEndpoint) -> Bool {
        !name.isEmpty && name == other.name && transport == other.transport
    }

    /// Whether the device sits on a bus a headset can physically sit on.
    ///
    /// Required alongside `isSameDevice`, and the aggregate device is why. An
    /// aggregate («Агрегатное устройство», transport `grup`) can be both ends at
    /// once while wrapping the Mac's own speakers and microphone — so «one
    /// device on both ends» alone would call the loudest possible route safe.
    /// A virtual device (`virt`, BlackHole) says nothing about the room either.
    /// Bluetooth and USB are buses a thing worn on the head actually uses.
    var isPeripheralBus: Bool {
        transport == AudioTransport.bluetooth || transport == AudioTransport.usb
    }

    /// Headphones in the jack — the only positive «the sound never reaches the
    /// room» this classifier has.
    ///
    /// Unlike the two above, this one is **not** measured: no wired headphones
    /// were plugged in when the machine was probed, so `hdpn` here is Apple's
    /// long-standing data-source convention and not a reading. That is
    /// deliberate rather than sloppy — if the convention is wrong, or if Apple
    /// Silicon exposes the jack as a separate device with no data source at all,
    /// this simply never returns `true` and every route falls back to
    /// «неизвестно», which keeps strict mode on. The one verdict that switches a
    /// defence *off* is the one that fails towards keeping it on.
    var isHeadphoneJack: Bool {
        transport == AudioTransport.builtIn && dataSource == AudioDataSource.headphones
    }
}

/// Four-character transport codes, spelled out where they are compared.
nonisolated enum AudioTransport {
    /// `kAudioDeviceTransportTypeBuiltIn` — the machine's own hardware.
    static let builtIn = "bltn"
    /// `kAudioDeviceTransportTypeBluetooth` — measured on the bench as the
    /// transport of the FreeBuds, which report no data source at all.
    static let bluetooth = "blue"
    /// `kAudioDeviceTransportTypeUSB` — a wired headset or an external interface.
    static let usb = "usb"
}

/// Four-character data-source codes.
///
/// Not public constants of Core Audio: they are read off the device and compared
/// as strings, exactly as `outprobe` printed them.
nonisolated enum AudioDataSource {
    static let internalSpeaker = "ispk"
    static let internalMicrophone = "imic"
    static let headphones = "hdpn"
}

/// Where the sound goes, and whether it comes back into the microphone.
///
/// **Three answers, and the third one is not a failure.** Classification is
/// unreliable and it was measured to be unreliable: of the four output devices on
/// the user's machine only the built-in speakers can be named at all — BlackHole
/// and Microsoft Teams Audio report the transport `virt`, the aggregate reports
/// `grup`, and `blue` / `usb` mean a headset and a desk speaker equally well. A
/// classifier that guessed would be wrong about most of the devices that exist,
/// and would be wrong *silently*, which is the class of failure this project has
/// already been bitten by twice.
///
/// So «неизвестно» is a verdict with its own wording and its own consequence:
/// strict mode stays on, and the window says what is known instead of pretending
/// to know the rest.
nonisolated enum AudioRoute: Equatable, Sendable {

    /// The output was positively identified as something that does not fill the
    /// room. Nothing leaks, whatever the microphone is.
    case safe(output: AudioEndpoint)

    /// Both ends named, and they are the painful pair: the built-in speakers
    /// playing into the built-in microphone. Measured without VPIO: 17.8 seconds
    /// of a 19-second question land in `You` (ADR-0009).
    case leaky(input: AudioEndpoint, output: AudioEndpoint)

    /// At least one end could not be named. Either endpoint may be missing
    /// entirely — a machine with no default output has none to describe.
    case unknown(input: AudioEndpoint?, output: AudioEndpoint?)

    /// Reads two endpoints and refuses to guess.
    ///
    /// The order of the two positive rules matters. Headphones are checked first
    /// and on their own, because they settle the question by themselves: sound
    /// that never enters the room cannot come back through any microphone. The
    /// leaky verdict needs **both** ends, because the measurement that justifies
    /// it had both — a USB microphone next to the same speakers leaks too, but
    /// nothing here can tell it from a headset boom microphone that barely does,
    /// and inventing a verdict for that pair is exactly the guessing this type
    /// exists to avoid.
    static func classify(input: AudioEndpoint?, output: AudioEndpoint?) -> AudioRoute {
        if let output, output.isHeadphoneJack {
            return .safe(output: output)
        }
        // One device on both ends, and it is not the Mac itself: a headset.
        //
        // This rule exists because without it the commonest kind of headphones —
        // Bluetooth — never leaves `.unknown`, and `.unknown` turns strict mode
        // on. The user would lose the beginning of every answer started over the
        // interlocutor, for the whole call, in the configuration where nothing
        // leaks at all. Measured on the bench: with the FreeBuds as both ends,
        // the transport is `blue` and there is no data source on either side —
        // no positive rule can ever fire.
        //
        // Both ends have to match, and that is the whole safety of it: a desk
        // microphone next to the Mac's own speakers does leak, and there input
        // and output are two different devices. One device cannot be both in the
        // room and in the ears.
        if let input, let output, input.isSameDevice(as: output), output.isPeripheralBus {
            return .safe(output: output)
        }
        if let output, output.isBuiltInSpeakers, let input, input.isBuiltInMicrophone {
            return .leaky(input: input, output: output)
        }
        return .unknown(input: input, output: output)
    }

    /// Whether the microphone has to be treated as carrying the other side's
    /// voice — the seam strict mode reads (`SessionEngine.isLeakyRoute`).
    ///
    /// Everything except a positively safe route answers `true`, and that
    /// asymmetry is the whole design. Being wrong towards strictness costs the
    /// first fraction of a second of an answer the user began on top of the
    /// interlocutor; being wrong the other way writes the interlocutor's voice
    /// into the transcript as the user's own — the failure that breaks the one
    /// guarantee the product has.
    var mayLeak: Bool {
        if case .safe = self { return false }
        return true
    }

    /// Whether the leak is certain rather than merely possible.
    ///
    /// The window says the two cases differently: a certain leak is worth a block
    /// mid-call, an uncertain one is a line read before the call and no more.
    var isCertainlyLeaky: Bool {
        if case .leaky = self { return true }
        return false
    }

    /// What to tell the user, or `nil` when there is nothing worth saying.
    ///
    /// Inside the window and nowhere else, like every other report in this app: a
    /// notification banner would be drawn over the shared screen (ADR-0004).
    var notice: String? {
        switch self {
        case .safe:
            // Nothing leaks and nothing is uncertain. A line saying «всё хорошо»
            // would take room from the suggestion feed every second of the call
            // to repeat something that is already true.
            nil
        case .leaky(_, let output):
            String(localized: """
            Звук идёт в «\(output.name)», а слушает встроенный микрофон: \
            голос собеседника попадает в канал You и пишется как ваша речь. \
            Наушники убирают это полностью — часть приложение отфильтрует само, но не всю.
            """)
        case .unknown(let input, let output):
            Self.unknownNotice(input: input, output: output)
        }
    }

    /// The uncertain case, said in whichever of its two shapes applies.
    ///
    /// Splitting them is not decoration. «Вывод — динамики, а микрофон опознать
    /// не удалось» is a different sentence from «вывод опознать не удалось»: the
    /// first one already knows that the sound is in the room and only the
    /// microphone is in question, and a user reading it can answer that question
    /// themselves in a second.
    private static func unknownNotice(input: AudioEndpoint?, output: AudioEndpoint?) -> String {
        guard let output else {
            return String(localized: "Устройство вывода не определяется. Если звук идёт в динамики, голос собеседника будет попадать в канал You — наушники это чинят.")
        }
        if output.isBuiltInSpeakers {
            let microphone = input.map { "«\($0.name)»" } ?? String(localized: "неизвестный")
            return String(localized: """
                Звук идёт в динамики, а микрофон — \(microphone), и опознать его не удалось. \
                Если он стоит рядом с ноутбуком, голос собеседника попадёт в канал You. \
                В наушниках этого не бывает вовсе.
                """)
        }
        return String(localized: """
            Маршрут звука определить не удалось: вывод — «\(output.name)». \
            Если это наушники, всё хорошо; если динамики — голос собеседника попадёт в канал You.
            """)
    }

    /// One short line for the lifecycle log.
    ///
    /// Device names and nothing else: they are configuration, not conversation.
    /// Written once per *change* of the verdict — a route that is re-read and
    /// found the same writes nothing, or an hour-long call would fill the log
    /// with the same sentence.
    var summary: String {
        switch self {
        case .safe(let output):
            "безопасный — вывод «\(output.name)»"  // не переводится: журнал
        case .leaky(let input, let output):
            "опасный — вывод «\(output.name)», вход «\(input.name)»"  // не переводится: журнал
        case .unknown(let input, let output):
            "неизвестный — вывод «\(output?.name ?? "—")», вход «\(input?.name ?? "—")»"  // не переводится: журнал
        }
    }

    /// Nothing has been read yet.
    ///
    /// The starting value of the monitor, and deliberately the uncertain one: a
    /// route that has not been looked at is not a safe route.
    static let unread = AudioRoute.unknown(input: nil, output: nil)
}
