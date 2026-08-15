#!/usr/bin/env python3
"""Разбор сохранённых диалогов и два набора реплик `You`: протечки и честные.

Измерительный прибор тикета 01, а не часть приложения. Живёт скриптом рядом со
спекой по образцу `.scratch/interview-packs/build.py`: разбор чужого формата и
статистика по нему в код приложения не идут.

Формат задан `TranscriptExport`: шапка, `---`, дальше записи `**Канал** · мм:сс`
со следующей строкой-телом. Записи «Подсказка» в наборы не идут, но читаются —
они разделяют реплики по времени.

    python3 .scratch/leak-detection/parse.py .scratch/leak-calls/*.md
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

RECORD = re.compile(r"^\*\*(Them|You|Подсказка[^*]*)\*\* · (\d+):(\d\d)$")
DROPPED = re.compile(r"выброшено как протечка: (\d+)")

# Нормализация ровно та же, что в LeakDedup.words: регистр, пунктуация и «ё».
# Расходиться им нельзя — иначе числа отсюда не про то правило, которое работает.
WORD = re.compile(r"[^\W_]+", re.UNICODE)


def words(text: str) -> list[str]:
    return WORD.findall(text.lower().replace("ё", "е"))


@dataclass
class Record:
    channel: str      # "Them" | "You" | "Подсказка"
    at: int           # секунды от начала записи
    text: str

    @property
    def words(self) -> list[str]:
        return words(self.text)


@dataclass
class Call:
    path: Path
    dropped: int = 0          # сколько строк фильтр уже перечеркнул: только счётчик
    records: list[Record] = field(default_factory=list)

    @property
    def turns(self) -> list[Record]:
        return [r for r in self.records if r.channel in ("Them", "You")]


def parse(path: Path) -> Call:
    call = Call(path=path)
    lines = path.read_text(encoding="utf-8").splitlines()

    for line in lines:
        if match := DROPPED.search(line):
            call.dropped = int(match.group(1))
            break

    index = 0
    while index < len(lines):
        match = RECORD.match(lines[index])
        if not match:
            index += 1
            continue
        channel, minutes, seconds = match.groups()
        # Тело записи — до пустой строки: у подсказки оно бывает многострочным.
        body: list[str] = []
        index += 1
        while index < len(lines) and lines[index].strip():
            body.append(lines[index])
            index += 1
        call.records.append(
            Record(
                channel="Подсказка" if channel.startswith("Подсказка") else channel,
                at=int(minutes) * 60 + int(seconds),
                text=" ".join(body).strip(),
            )
        )
    return call


def longest_common_subsequence(mine: list[str], theirs: list[str]) -> int:
    """То же, что LeakDedup.commonSubsequenceLength."""
    if not mine or not theirs:
        return 0
    previous = [0] * (len(theirs) + 1)
    for word in mine:
        current = [0] * (len(theirs) + 1)
        for i, other in enumerate(theirs):
            current[i + 1] = (
                previous[i] + 1 if word == other else max(previous[i + 1], current[i])
            )
        previous = current
    return previous[-1]


def longest_common_run(mine: list[str], theirs: list[str]) -> int:
    """Длиннейшее непрерывное совпадение — признак-кандидат «непрерывность».

    Протечка воспроизводит подряд идущий кусок речи `Them`; случайное совпадение
    рассыпано, и подпоследовательности это безразлично, а подстроке нет.
    """
    if not mine or not theirs:
        return 0
    best = 0
    previous = [0] * (len(theirs) + 1)
    for word in mine:
        current = [0] * (len(theirs) + 1)
        for i, other in enumerate(theirs):
            if word == other:
                current[i + 1] = previous[i] + 1
                best = max(best, current[i + 1])
        previous = current
    return best


def neighbours(call: Call, turn: Record, window: int = 20) -> list[Record]:
    """Речь `Them` рядом по времени.

    Длительности в файле нет — только момент начала, — поэтому пересечение,
    которое `LeakDedup.overlap` считает по отрезкам, здесь **приблизительное**:
    берётся окно вокруг реплики. Число печатается рядом с выводом, чтобы было
    видно, чем он подпёрт.
    """
    return [
        r for r in call.records
        if r.channel == "Them" and abs(r.at - turn.at) <= window
    ]


def report(call: Call) -> None:
    you = [r for r in call.turns if r.channel == "You"]
    them = [r for r in call.turns if r.channel == "Them"]

    print(f"\n{'=' * 78}\n{call.path.name}")
    print(f"{'=' * 78}")
    print(f"Them: {len(them)}   You: {len(you)}   "
          f"уже перечёркнуто фильтром: {call.dropped} (текста нет, только счёт)")
    print()
    print(f"{'время':>7} {'слов':>5} {'совп':>5} {'покр':>6} {'ряд':>4}  реплика You")
    print(f"{'-' * 78}")

    for turn in you:
        mine = turn.words
        theirs: list[str] = []
        for near in neighbours(call, turn):
            theirs.extend(near.words)
        matched = longest_common_subsequence(mine, theirs)
        run = longest_common_run(mine, theirs)
        coverage = matched / len(mine) if mine else 0.0
        # Как решило бы нынешнее правило: покрытие ≥ 0.83 при ≥ 5 совпавших.
        verdict = "ПОМЕТИЛ" if matched >= 5 and coverage >= 0.83 else ""
        stamp = f"{turn.at // 60:02d}:{turn.at % 60:02d}"
        print(f"{stamp:>7} {len(mine):>5} {matched:>5} {coverage:>6.2f} {run:>4}  "
              f"{turn.text[:60]:<60} {verdict}")


def main() -> int:
    paths = [Path(a) for a in sys.argv[1:]]
    if not paths:
        print(__doc__)
        return 1
    for path in paths:
        report(parse(path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
