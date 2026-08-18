#!/bin/bash
#
# Находит строки интерфейса, которые остались непереведёнными.
#
#   ./scripts/find-untranslated.sh          # молчит, если всё в порядке
#
# Зачем это существует. Забытая строка в этом проекте **не падает и не пустеет**:
# ключом в каталоге служит сам русский текст, поэтому непереведённое просто
# приходит по-русски и встаёт посреди английского экрана. Увидит это пользователь.
# Один раз так и вышло — 0.5.0 уехал с полусотней русских строк на английском окне,
# потому что проверяли глазами.
#
# Что именно ищется: кириллический литерал, который **не** локализуется. Литерал
# сразу за `Text(`, `Button(`, `Section(` и прочими, принимающими
# `LocalizedStringKey`, переводится сам. Литерал, попадающий в `String`, — нет, и
# ему нужен `String(localized:)`. Разница неочевидна на глаз и стоила релиза.

set -euo pipefail
cd "$(dirname "$0")/.."
SRC="GhostMeet/GhostMeet"

python3 - "$SRC" <<'PY'
import os, re, sys

src = sys.argv[1]
LIT = re.compile(r'"(?:[^"\\\n]|\\.)*"')
CYR = re.compile(r'[А-Яа-яЁё]')
# Конструкции, принимающие LocalizedStringKey: литерал за ними переводится сам.
SELF = re.compile(
    r'(Text|Label|Button|Section|Picker|Toggle|SettingsRow|Stepper|Link|TextField'
    r'|SecureField|help|accessibilityLabel|navigationTitle|localized:)\(\s*$'
)

# Файлы, где русский текст — не интерфейс, а данные, и переводить его нельзя.
#
# Промпты сверяются с docs/GhostMeet-Prompts.md дословно; фантомные фразы — это
# то, что говорит Whisper, а не мы; `UserProfile` и `InterviewContext.label`
# задают ФОРМУ промпта, и `parsed(from:)` разбирает ответ модели ровно по ним.
EXEMPT = {
    "Intelligence/Context/AssistPrompt.swift",
    "Intelligence/Context/BriefPrompt.swift",
    "Intelligence/Context/AskPrompt.swift",
    "Intelligence/Context/SolvePrompt.swift",
    "Intelligence/Context/PromptFragments.swift",
    "Intelligence/Context/ResumeProfilePrompt.swift",
    "Intelligence/Context/TranscriptFormatter.swift",
    "Speech/PhantomSpeech.swift",
    "Settings/UserProfile.swift",
    "Settings/InterviewContext.swift",
    # Замена «ё» на «е» при сравнении слов — это данные, а не текст для чтения.
    "Intelligence/Context/LeakDedup.swift",
}

found = []

def multiline_blocks(lines):
    """Диапазоны строк внутри многострочных литералов и то, чем они открыты.

    Однострочный литерал видно по кавычкам; многострочный — нет, и первая
    редакция скрипта его попросту не замечала. Пропустила она ровно то, ради
    чего писалась: предупреждение про резюме, живущее в `\"\"\"…\"\"\"`.
    """
    blocks, start, opener = [], None, ""
    for i, line in enumerate(lines):
        if line.count('"""') != 1:
            continue
        if start is None:
            start, opener = i, line
        else:
            blocks.append((start, i, opener))
            start, opener = None, ""
    return blocks

for root, _, files in os.walk(src):
    for name in sorted(files):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(root, name)
        rel = os.path.relpath(path, src)
        if rel in EXEMPT:
            continue
        lines = open(path, encoding="utf-8").read().split("\n")

        # Многострочные литералы: смотрим на строку, которая их открывает —
        # именно там стоит `String(localized:` или `Text(`, если он локализован.
        for start, end, opener in multiline_blocks(lines):
            body = "\n".join(lines[start + 1 : end])
            if not CYR.search(body):
                continue
            if "String(localized:" in opener or SELF.search(opener.rstrip()[:-3]) \
               or re.search(r'(Text|Label|Button|Section|localized:)\(\s*$', opener.rstrip()[:-3]):
                continue
            if "не переводится" in opener:
                continue
            # Журнал часто выглядит так: `log.info(` на одной строке, а `"""` —
            # на следующей. Смотрим на пару строк выше, иначе многострочная
            # запись в журнал выглядит как непереведённый текст.
            if any("log." in l or "Logger(" in l for l in lines[max(0, start - 2) : start]):
                continue
            # `#Preview` — витрина для Xcode, а не экран пользователя: текст в
            # ней подобран, чтобы было видно разметку, и переводить его незачем.
            if any("#Preview" in l for l in lines[max(0, start - 40) : start]) \
               and not any(l.startswith("struct ") or l.startswith("final class ")
                           for l in lines[max(0, start - 40) : start]):
                continue
            first = next((l.strip() for l in lines[start + 1 : end] if l.strip()), "")
            found.append(f"{rel}:{start + 1}: \"\"\"{first[:70]}")

        for number, line in enumerate(lines, 1):
            stripped = line.lstrip()
            # Комментарии и журнал: журнал не переводится намеренно — иначе
            # перестаёт искаться сообщение, о котором рассказал пользователь.
            if stripped.startswith("//") or "log." in line or "Logger(" in line:
                continue
            # Явная пометка для строк, которые переводить нельзя: журнал,
            # разбитый на несколько строк, и нормализация текста. Пометка стоит
            # в самом коде, поэтому не расходится с ним, как разошёлся бы
            # список путей в этом скрипте.
            if "не переводится" in line:
                continue
            for match in LIT.finditer(line):
                if not CYR.search(match.group(0)):
                    continue
                before = line[: match.start()]
                if "String(localized:" in before or SELF.search(before):
                    continue
                found.append(f"{rel}:{number}: {match.group(0)[:78]}")

if found:
    print(f"✗ Непереведённых строк: {len(found)}")
    for line in found:
        print(f"    {line}")
    print()
    print("  Литерал, уходящий в String, надо обернуть в String(localized:).")
    print("  Если это журнал или форма промпта — место ему в списке исключений скрипта.")
    raise SystemExit(1)

print("  непереведённых строк интерфейса нет")
PY
