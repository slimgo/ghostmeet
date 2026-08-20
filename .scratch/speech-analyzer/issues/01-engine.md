# 01 — Движок за протоколом

**What to build:** реализация `SpeechRecognizer` поверх `SpeechAnalyzer`, доступная
только на macOS 26 и выше.

**Форма.** `Speech/NativeSpeechRecognizer.swift`, `@available(macOS 26, *)`, актор.
Один анализатор на экземпляр, экземпляр — на канал: общий анализатор на два канала
даёт общую очередь и взаимную блокировку.

**Что подавать.** Протокол отдаёт `SpeechAudio` — моно-сэмплы и частоту. Нативный API
принимает `AnalyzerInput` с `AVAudioPCMBuffer`; формат берётся у
`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`, а не назначается нами.
**Заявленному формату здесь не верят так же, как в `Audio/`**: несовпадение частот
даёт не ошибку, а тишину или кашу.

**Локаль.** `DictationTranscriber`, а не `SpeechTranscriber`: у первого 54 локали и
`ru-RU` среди них, у второго — тридцать без единой кириллической (замер в спеке).
Локаль берётся от языка разговора, а не от языка интерфейса. Ассеты: если
`AssetInventory.assetInstallationRequest(supporting:)` вернул запрос — скачать и
дождаться, состояние показать так же, как показывается загрузка модели Whisper
(`SpeechModelStatus`).

**Пунктуация.** `.punctuation` передаётся, хотя на русском замер её действия не
показал: на английском она может работать, а молча не передать опцию — хуже.

**Acceptance:**
- на macOS 26 распознаёт русскую и английскую реплику, текст непустой;
- на macOS 14–15 путь не существует: сборка проходит, движок в списке не появляется;
- каналы не блокируют друг друга — два распознавания идут одновременно;
- отказ движка не роняет сессию, а возвращает ошибку через протокол;
- закрыто тестами; тяжёлое не запускается под тестами (`AppDefaults.isRunningTests()`).

**Читать:** [спека](../spec.md) · `Speech/SpeechRecognizer.swift` · `Speech/WhisperSpeechRecognizer.swift` · [ADR-0001](../../../docs/adr/0001-swappable-backends-behind-protocols.md)

**Blocked by:** None.

**Status:** ready-for-agent
