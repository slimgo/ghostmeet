#!/usr/bin/env python3
"""Собирает паки собеседований из шаблона и сценариев.

    python3 .scratch/interview-packs/build.py

Каждый пак — **одна самодостаточная страница** в своей папке. Не из любви к
простоте: паки открывают как файл, а браузер запрещает `file://` подтягивать
соседние скрипты модулями. Разложенный на файлы пак у коллеги просто не
запустится, и он решит, что сборка битая.

На выходе `dist/`: папка на специализацию, страница-указатель и архив, который
и отдают.
"""

import json
import re
import pathlib
import shutil
import zipfile

HERE = pathlib.Path(__file__).parent
TEMPLATE = HERE / "template.html"
SCRIPTS = HERE / "scripts"
STRINGS = HERE / "strings"
DIST = HERE / "dist"

# Порог, по которому приложение закрывает реплику, — 1.5 с. Паузы в паках
# держатся ниже его сознательно: длинные разрывы на прогоне раздражали, а
# проверить разрезанный вопрос всё равно можно ползунком «Паузы» на странице.
MAX_GAP = 1000


def load(path: pathlib.Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    for entry in data["entries"]:
        for chunk in entry["chunks"]:
            if chunk["gap"] > MAX_GAP:
                raise SystemExit(f"{path.name}: пауза {chunk['gap']} мс больше потолка {MAX_GAP}")
        # У последнего куска паузы быть не должно: за ней идёт либо ожидание
        # ответа, либо следующая реплика, и лишний разрыв только тянет время.
        entry["chunks"][-1]["gap"] = 0
    return data


def strings(language: str) -> dict:
    """Словарь страницы на языке пака.

    Плеер один на оба языка: он редко меняется, а два его экземпляра разошлись
    бы на первой же правке — ровно так, как расходятся два описания одного
    порядка. Языковое здесь только это, и оно снаружи.
    """
    path = STRINGS / f"{language}.json"
    if not path.exists():
        raise SystemExit(f"нет словаря для языка «{language}»: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def page(data: dict, template: str) -> str:
    script = [
        {
            "phase": e["phase"],
            "kind": e["kind"],
            **({"hint": e["hint"]} if e.get("hint") else {}),
            **({"tail": True} if e.get("tail") else {}),
            **({"who": e["who"]} if e.get("who", 1) != 1 else {}),
            "chunks": [[c["text"], c["gap"]] for c in e["chunks"]],
        }
        for e in data["entries"]
    ]
    setup = {"profile": data["profile"], "context": data["context"]}
    # Язык объявлен в самом сценарии: от него зависят и словарь страницы, и —
    # что важнее — голоса. Английский пак, читаемый русским голосом, не
    # проверяет ничего.
    language = data.get("language", "ru")
    words = strings(language)
    html = (
        template
        .replace("__LANG__", language)
        .replace("__TITLE__", f"{words['pageTitle']} — {data['title']}")
        .replace("__ROLE__", data["title"])
        .replace("__STRINGS__", json.dumps(words, ensure_ascii=False, indent=1))
        .replace("__SCRIPT__", json.dumps(script, ensure_ascii=False, indent=1))
        .replace("__SETUP__", json.dumps(setup, ensure_ascii=False, indent=1))
    )
    # Плейсхолдеры разметки — то, что подставляется один раз и не участвует в
    # коде страницы.
    for key, value in words.items():
        if key.isupper():
            html = html.replace(f"__T_{key}__", value)
    leftover = re.search(r"__T_[A-Z_]+__|__LANG__|__STRINGS__", html)
    if leftover:
        raise SystemExit(f"{data['slug']}: в странице остался плейсхолдер {leftover.group(0)}")
    return html


def index(packs: list[dict]) -> str:
    rows = "\n".join(
        f'    <li><a href="{p["slug"]}/index.html">{p["title"]}</a>'
        f' — {p["questions"]} вопросов, {p["phases"]} этапов</li>'
        for p in packs
    )
    return f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<title>Паки собеседований — GhostMeet</title>
<style>
 body{{font:15px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;max-width:760px;margin:40px auto;padding:0 20px;
      color-scheme:light dark}}
 h1{{font-size:22px}} li{{margin-bottom:6px}} code{{background:rgba(128,128,128,.15);padding:1px 5px;border-radius:4px}}
 .hint{{color:#6b6b73;font-size:13.5px;border:1px solid rgba(128,128,128,.3);border-radius:10px;padding:12px 14px}}
</style></head><body>
<h1>Паки собеседований</h1>
<p>Каждый пак — одно интервью целиком: страница играет интервьюера голосом, задаёт вопрос и ждёт, пока вы ответите.
Откройте свой и идите сверху вниз.</p>
<ul>
{rows}
</ul>
<div class="hint">
<b>Перед прогоном.</b> Впишите в настройки GhostMeet профиль и заготовки — они напечатаны в самом паке, с кнопкой
«Скопировать». Выберите браузер источником канала <code>Them</code> и включите прослушивание.<br><br>
<b>Голоса.</b> Их два — основной интервьюер и второй, который подключается ближе к концу. Русских голосов в macOS из
коробки мало; ещё несколько, включая улучшенные, ставятся в «Системных настройках» → «Универсальный доступ» →
«Устная речь» → «Системный голос» → «Настроить».<br><br>
<b>Аккорды:</b> <code>⌥⌘A</code> коротко, <code>⌥⌘Z</code> подробно, <code>⌥⌘X</code> решить с экрана.
</div>
</body></html>
"""


def main() -> None:
    template = TEMPLATE.read_text(encoding="utf-8")
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)

    packs = []
    for path in sorted(SCRIPTS.glob("*.json")):
        data = load(path)
        folder = DIST / data["slug"]
        folder.mkdir()
        (folder / "index.html").write_text(page(data, template), encoding="utf-8")
        questions = sum(1 for e in data["entries"] if e["kind"] == "q")
        packs.append({
            "slug": data["slug"],
            "title": data["title"],
            "questions": questions,
            "phases": len(dict.fromkeys(e["phase"] for e in data["entries"])),
        })
        print(f"  {data['slug']:<16} {questions} вопросов, {packs[-1]['phases']} этапов")

    (DIST / "index.html").write_text(index(packs), encoding="utf-8")

    archive = DIST / "interview-packs.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for file in sorted(DIST.rglob("*.html")):
            zf.write(file, file.relative_to(DIST))
    size = archive.stat().st_size / 1024
    print(f"\n✓ {len(packs)} паков, архив {archive} ({size:.0f} КБ)")


if __name__ == "__main__":
    main()
