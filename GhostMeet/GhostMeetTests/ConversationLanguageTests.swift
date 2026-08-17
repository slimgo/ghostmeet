//
//  ConversationLanguageTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

private func turns(_ texts: String...) -> [Turn] {
    texts.enumerated().map { index, text in
        Turn(
            id: UUID(),
            channel: index.isMultiple(of: 2) ? .them : .you,
            text: text,
            timestamp: TimeInterval(index),
            duration: 1
        )
    }
}

@Suite("Язык разговора решает судьбу одного правила промпта")
struct ConversationLanguageTests {

    @Test("Русский разговор — русский")
    func russianConversation() {
        let transcript = turns(
            "Расскажите, как вы устроили очередь сообщений в этом проекте?",
            "Мы взяли Kafka и разложили по партициям, ключом брали идентификатор заказа."
        )
        #expect(ConversationLanguage.detected(in: transcript) == .russian)
    }

    /// Ровно тот случай, ради которого порог не «есть латиница», а «латиницы
    /// вчетверо больше»: техническая русская речь наполовину состоит из
    /// латинских терминов и английской от этого не становится.
    @Test("Русская речь с латинскими терминами — всё ещё русская")
    func russianWithLatinTerms() {
        let transcript = turns(
            "Мы подняли Kubernetes через Helm, а PostgreSQL держим в StatefulSet с PVC.",
            "Мониторинг — Prometheus и Grafana, алерты в Alertmanager."
        )
        #expect(ConversationLanguage.detected(in: transcript) == .russian)
    }

    @Test("Английский разговор — английский")
    func englishConversation() {
        let transcript = turns(
            "Can you walk me through how you designed the message queue in that project?",
            "We used Kafka, partitioned by order id, with an outbox table on the producer side."
        )
        #expect(ConversationLanguage.detected(in: transcript) == .english)
    }

    /// Нажали до того, как кто-то заговорил. Русский по умолчанию — на нём
    /// написаны промпты, и ответа, которому правило могло бы навредить, ещё нет.
    @Test("Пустой транскрипт — русский по умолчанию")
    func emptyTranscriptFallsBack() {
        #expect(ConversationLanguage.detected(in: []) == .default)
        #expect(ConversationLanguage.detected(in: turns("Yes.")) == .russian)
    }
}

@Suite("Правило скобок уходит только в русский промпт")
struct PronunciationRuleTests {

    /// Правило существует потому, что подсказку **читают вслух**, а латиницу
    /// вслух не прочесть внутри русской фразы. На английском собеседовании
    /// ответ английский, и кириллический глосс посреди него — не нюанс, а
    /// нечитаемая фраза.
    @Test("Русский разговор: правило на месте")
    func russianKeepsTheRule() {
        let prompt = BriefPrompt.system(profile: .empty, language: .russian)
        #expect(prompt.contains(PromptFragment.pronunciation))
        #expect(AssistPrompt.system(profile: .empty, language: .russian)
            .contains(PromptFragment.pronunciation))
    }

    @Test("Английский разговор: правила нет вовсе")
    func englishDropsTheRule() {
        let brief = BriefPrompt.system(profile: .empty, language: .english)
        let detailed = AssistPrompt.system(profile: .empty, language: .english)

        #expect(brief.contains(PromptFragment.pronunciation) == false)
        #expect(detailed.contains(PromptFragment.pronunciation) == false)
        // Не «правило переписано мягче», а именно отсутствует: примера с
        // кириллицей в скобках не остаётся ни одного.
        #expect(brief.contains("(энджин-икс)") == false)
        #expect(detailed.contains("(кубернетис)") == false)
    }

    /// Остальное в промпте от языка не зависит: меняется одно правило, а не
    /// характер подсказки.
    @Test("Меняется только это правило")
    func nothingElseChanges() {
        let russian = BriefPrompt.system(profile: .empty, language: .russian)
        let english = BriefPrompt.system(profile: .empty, language: .english)

        #expect(russian.contains(PromptFragment.voice))
        #expect(english.contains(PromptFragment.voice))
        #expect(english.contains(PromptFragment.outOfStack))
        #expect(english.contains(PromptFragment.questionKinds))
    }

    /// Умолчание — русский, и это то, что сверяется с `docs/GhostMeet-Prompts.md`.
    @Test("Без указания языка промпт остаётся прежним")
    func defaultsToRussian() {
        #expect(BriefPrompt.system(profile: .empty)
                == BriefPrompt.system(profile: .empty, language: .russian))
        #expect(AssistPrompt.system(profile: .empty)
                == AssistPrompt.system(profile: .empty, language: .russian))
    }

    /// Язык берётся из разговора, а не из настроек: проверяется на собранном
    /// запросе, то есть на том пути, которым промпт уходит на самом деле.
    @Test("Английский транскрипт даёт запрос без правила")
    func theRequestFollowsTheTranscript() {
        let english = turns(
            "Could you describe how the retry policy works in that service?",
            "We back off exponentially and give up after five attempts, then the message goes to a dead letter queue."
        )
        let request = BriefPrompt.request(transcript: english, profile: .empty)
        #expect(request.systemPrompt.contains(PromptFragment.pronunciation) == false)

        let russian = turns(
            "Расскажите, как у вас устроены повторы в этом сервисе?",
            "Отходим по экспоненте и сдаёмся после пяти попыток, дальше сообщение уходит в очередь недоставленных."
        )
        let russianRequest = BriefPrompt.request(transcript: russian, profile: .empty)
        #expect(russianRequest.systemPrompt.contains(PromptFragment.pronunciation))
    }
}
