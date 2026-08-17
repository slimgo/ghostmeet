#!/bin/bash
#
# Выпускает релиз GhostMeet: проверяет, собирает, подписывает, тегает, публикует.
#
#   ./scripts/release.sh 0.2.0        # спросит перед тем, как что-то отправить наружу
#   ./scripts/release.sh 0.2.0 --yes  # без вопросов (для повторного прогона)
#   ./scripts/release.sh 0.2.0 --dry-run  # всё локально, ничего не отправлять
#
# Почему релиз собирается здесь, а не в CI. Разрешения macOS привязаны к подписи, а подпись у
# проекта одна — личный сертификат Apple Development. Отдать его закрытую часть в secrets значит
# разрешить подписывать вашим именем всякому, кто получит доступ к репозиторию; собирать в CI без
# подписи значит выдать коллегам сборку, которая заново просит микрофон и запись экрана. Поэтому
# CI собирает и прогоняет тесты, а подписывает эта машина.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
PROJECT="$ROOT/GhostMeet/GhostMeet.xcodeproj"
DERIVED="$ROOT/.build/release-derived"
CHANGELOG="$ROOT/CHANGELOG.md"

VERSION="${1:-}"
ASSUME_YES=no
DRY_RUN=no
for arg in "${@:2}"; do
  case "$arg" in
    --yes) ASSUME_YES=yes ;;
    --dry-run) DRY_RUN=yes ;;
    *) echo "✗ Неизвестный ключ: $arg"; exit 1 ;;
  esac
done

fail() { echo "✗ $1"; exit 1; }

# Адрес ленты обновлений — один на всё, и живёт он там, где его читает
# приложение. Записать его здесь вторым экземпляром значило бы завести два
# адреса, которые обязаны совпадать: приложение спрашивает по вшитому, а ассет
# выкладывается под именем отсюда, и разойдясь однажды они дадут установленным
# копиям тихое «обновлений нет».
#
# GitHub по .../releases/latest/download/<имя> всегда отдаёт ассет последнего
# релиза, не зная его номера, — потому адрес и может быть вшит в сборку.
FEED_URL="$(plutil -extract SUFeedURL raw -o - "$ROOT/GhostMeet/Info.plist" 2>/dev/null || true)"
[ -n "$FEED_URL" ] \
  || { echo "✗ В GhostMeet/Info.plist нет SUFeedURL — обновлять по чему-то надо"; exit 1; }
APPCAST_NAME="${FEED_URL##*/}"
PRODUCT_LINK="https://github.com/slimgo/ghostmeet"

[ -n "$VERSION" ] || fail "Укажите версию: ./scripts/release.sh 0.2.0"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "Версия должна быть MAJOR.MINOR.PATCH, а не «$VERSION»"

TAG="v$VERSION"

echo "▸ Проверки перед релизом…"

# Закрытый ключ обновлений в дереве — это отказ выпускать, а не предупреждение.
# .gitignore его закрывает, но .gitignore молчалив: он не мешает `git add -f`, не
# видит уже отслеживаемый файл и ничего не скажет тому, кто выгрузил ключ через
# `generate_keys -x` и забыл убрать. Цена выше, чем у утёкшего сертификата:
# подписанное этим ключом обновление приложение поставит само, не спросив
# пользователя. Ключ живёт в Keychain, и в дереве ему взяться неоткуда — значит
# любое совпадение здесь означает, что что-то пошло не так.
KEY_PATTERNS=(-name '*.pem' -o -name '*.p12' -o -name '*private*key*' -o -name '*_private_key*')
STRAY_KEYS="$(find . -type f \( "${KEY_PATTERNS[@]}" \) \
  -not -path './.git/*' -not -path './.build/*' -not -path './dist/*' 2>/dev/null)"
TRACKED_KEYS="$(git ls-files -- '*.pem' '*.p12' '*private*key*' '*_private_key*')"
if [ -n "$STRAY_KEYS$TRACKED_KEYS" ]; then
  echo "✗ В дереве найден файл, похожий на закрытый ключ:"
  printf '%s\n' $STRAY_KEYS $TRACKED_KEYS | sed 's/^/    /'
  fail "Уберите его. Ключ подписи обновлений живёт в Keychain, а не в файле рядом с кодом"
fi

# Грязное дерево — это релиз из того, чего нет в истории: тег будет указывать на один код,
# а DMG собран из другого, и разойдутся они молча.
[ -z "$(git status --porcelain)" ] || fail "Рабочее дерево грязное — закоммитьте или отложите правки"

# Существующий тег — препятствие только если он указывает не сюда. Указывающий на HEAD
# означает ровно то, что нужно: версия уже помечена, осталось собрать и выложить. Так выпускается
# первый релиз после того, как теги проставлены задним числом, и так же повторяется прогон,
# упавший после того, как тег уже поставлен.
TAG_EXISTS=no
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] \
    || fail "Тег $TAG уже есть и указывает на другой коммит — снимите его или возьмите другую версию"
  TAG_EXISTS=yes
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "  ⚠ ветка $BRANCH, не main"

grep -q "^## \[$VERSION\]" "$CHANGELOG" \
  || fail "В CHANGELOG.md нет раздела ## [$VERSION] — релиз без записи о том, что в нём"

PROJECT_VERSION="$(xcodebuild -project "$PROJECT" -showBuildSettings -target GhostMeet 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION / {print $2; exit}')"
[ "$PROJECT_VERSION" = "$VERSION" ] \
  || fail "MARKETING_VERSION в проекте — $PROJECT_VERSION, а релиз $VERSION. Поправьте проект и закоммитьте"

if [ "$TAG_EXISTS" = yes ]; then
  echo "  дерево чистое, тег $TAG уже на этом коммите, CHANGELOG и проект согласны на $VERSION"
else
  echo "  дерево чистое, тега нет, CHANGELOG и проект согласны на $VERSION"
fi

# Тесты гоняются до сборки образа: собранный и подписанный DMG со сломанными тестами — это
# двадцать минут, потраченных на то, чтобы его выбросить.
echo "▸ Тесты…"
TEST_LOG="$ROOT/.build/release-tests.log"
mkdir -p "$ROOT/.build"
set +e
xcodebuild -project "$PROJECT" -scheme GhostMeet -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" test >"$TEST_LOG" 2>&1
TEST_STATUS=$?
set -e

# «✔ Test run with 0 tests in N suites passed» — это упавший host-процесс, а не успех: сюиты
# объявились, приложение умерло до первого теста, и их ноль тестов честно не упал. Один раз эта
# строка уже была принята за зелёный прогон.
if grep -q "Test run with 0 tests" "$TEST_LOG"; then
  fail "Ноль тестов — host-приложение упало на старте. Смотрите ~/Library/Logs/DiagnosticReports/GhostMeet-*.ips и $TEST_LOG"
fi
[ $TEST_STATUS -eq 0 ] || fail "Тесты упали (код $TEST_STATUS), подробности в $TEST_LOG"

TEST_COUNT="$(grep -oE "Test run with [0-9]+ test" "$TEST_LOG" | tail -1 | grep -oE '[0-9]+' || echo '?')"
echo "  прошло тестов: $TEST_COUNT"

echo "▸ Сборка образа…"
"$ROOT/scripts/make-dmg.sh" "$VERSION"
DMG="$ROOT/dist/GhostMeet-$VERSION.dmg"
[ -f "$DMG" ] || fail "make-dmg.sh не оставил $DMG"

# Заметки к релизу берутся из CHANGELOG, а не пишутся заново: два описания одного релиза
# расходятся на первой же правке.
NOTES="$ROOT/.build/release-notes-$VERSION.md"
awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" { inside = 1; next }
  inside && /^## \[/ { exit }
  inside { print }
' "$CHANGELOG" > "$NOTES"
[ -s "$NOTES" ] || fail "Раздел ## [$VERSION] в CHANGELOG пуст"

# ─── Лента обновлений ───────────────────────────────────────────────────────
#
# Делается здесь, а не отдельной ручной привычкой: забытый шаг «обновить
# appcast» даёт установленным копиям тихое «обновлений нет» вместо вышедшей
# версии, и заметит это никто. Ошибка в ленте доезжает до каждой машины
# одновременно, поэтому все проверки ниже стоят до публикации — как и весь
# остальной скрипт.
echo "▸ Лента обновлений…"

# Инструменты берутся из артефакта SPM, распакованного сборкой, а не качаются:
# подписывать обновление тем, что скачано только что, значит поставить всю
# защиту в зависимость от одной удачной загрузки.
find_sparkle_tool() {
  local tool="$1" found
  found="$(find "$ROOT/.build" -type f -path '*/artifacts/*/Sparkle/bin/'"$tool" 2>/dev/null | head -1)"
  [ -z "$found" ] && found="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f \
    -path '*/artifacts/*/Sparkle/bin/'"$tool" 2>/dev/null | head -1)"
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

GENERATE_APPCAST="$(find_sparkle_tool generate_appcast)" \
  || fail "Не найден generate_appcast. Он приезжает с зависимостью Sparkle — соберите проект"
SIGN_UPDATE="$(find_sparkle_tool sign_update)" \
  || fail "Не найден sign_update (тот же артефакт Sparkle, что и generate_appcast)"

# Лента строится из каталога, где лежит ровно один образ — выпускаемый. dist/
# для этого не годится: там семь версий подряд, и лента из него предложила бы
# машине выбор из истории проекта.
FEED_DIR="$ROOT/.build/appcast"
rm -rf "$FEED_DIR"; mkdir -p "$FEED_DIR"
cp "$DMG" "$FEED_DIR/"
# Заметки к версии — те же, что уйдут в релиз: третье описание одного релиза
# разошлось бы с двумя другими на первой правке.
cp "$NOTES" "$FEED_DIR/GhostMeet-$VERSION.md"

DOWNLOAD_PREFIX="https://github.com/slimgo/ghostmeet/releases/download/$TAG/"
APPCAST="$FEED_DIR/$APPCAST_NAME"
"$GENERATE_APPCAST" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "$PRODUCT_LINK" \
  --embed-release-notes \
  -o "$APPCAST" "$FEED_DIR" >/dev/null \
  || fail "generate_appcast не отработал"

[ -s "$APPCAST" ] || fail "generate_appcast не оставил $APPCAST"

# Подпись проверяется отдельно и обязательно, потому что её отсутствие — самый
# тихий отказ во всей цепочке: generate_appcast подписывает, только если нашёл
# SUPublicEDKey в бандле, а не найдя — молча выдаёт неподписанную ленту и
# возвращает ноль. Измерено на 0.3.3, у которой этого ключа ещё не было.
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST" | head -1)"
[ -n "$SIGNATURE" ] \
  || fail "В ленте нет sparkle:edSignature — проверьте SUPublicEDKey в бандле и ключ в Keychain"

# И проверяется по существу: подпись есть — не значит, что она от этого файла.
"$SIGN_UPDATE" --verify "$DMG" "$SIGNATURE" >/dev/null 2>&1 \
  || fail "Подпись в ленте не сходится с $DMG — обновление не установится ни у кого"

# Версия и адрес в ленте — то, по чему установленная копия решает, обновляться
# ли и откуда качать. Разъедься они с релизом, и ошибка вылезет у пользователя.
FEED_VERSION="$(sed -n 's|.*<sparkle:shortVersionString>\(.*\)</sparkle:shortVersionString>.*|\1|p' "$APPCAST" | head -1)"
[ "$FEED_VERSION" = "$VERSION" ] \
  || fail "В ленте версия $FEED_VERSION, а выпускается $VERSION"
grep -q "url=\"$DOWNLOAD_PREFIX$(basename "$DMG")\"" "$APPCAST" \
  || fail "В ленте адрес образа не тот, что будет у ассета релиза"

echo "  версия $FEED_VERSION, подпись сходится, адрес $DOWNLOAD_PREFIX$(basename "$DMG")"

if [ "$TAG_EXISTS" = yes ]; then
  echo "▸ Тег $TAG уже стоит на этом коммите — оставляю как есть"
else
  echo "▸ Тег $TAG…"
  git tag -a "$TAG" -m "GhostMeet $VERSION" -m "$(cat "$NOTES")"
fi

if [ "$DRY_RUN" = yes ]; then
  echo
  echo "✓ Локально готово: $DMG, лента $APPCAST, тег $TAG."
  echo "  --dry-run: наружу ничего не отправлено. Отменить тег: git tag -d $TAG"
  exit 0
fi

echo
echo "Дальше — наружу:"
echo "  • git push origin $BRANCH --follow-tags"
echo "  • релиз $TAG на GitHub с файлами $(basename "$DMG") и $APPCAST_NAME"
if [ "$ASSUME_YES" != yes ]; then
  read -r -p "Публиковать? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Остановился. Локально всё готово; тег снимается через git tag -d $TAG"; exit 0 ;;
  esac
fi

echo "▸ Push…"
git push origin "$BRANCH" --follow-tags

if command -v gh >/dev/null 2>&1; then
  # Образ и лента уезжают одним вызовом. Порознь они уехали бы порознь и
  # однажды: релиз без ленты — это тихое «обновлений нет» на каждой машине,
  # потому что адрес latest/download/appcast.xml начинает указывать в пустоту.
  echo "▸ Релиз на GitHub…"
  gh release create "$TAG" "$DMG" "$APPCAST" --title "GhostMeet $VERSION" --notes-file "$NOTES"

  # Лента — единственный ассет, который читает не человек, а установленные
  # копии, и читают они его по вшитому адресу. Проверяется, что адрес отвечает.
  echo "▸ Проверка ленты по вшитому адресу…"
  FEED_STATUS="$(curl -sSL -o /dev/null -w '%{http_code}' "$FEED_URL" || echo 000)"
  [ "$FEED_STATUS" = "200" ] \
    && echo "  $FEED_URL отвечает 200" \
    || echo "  ⚠ $FEED_URL ответил $FEED_STATUS — установленные копии обновлений не увидят"

  echo
  echo "✓ $TAG опубликован"
else
  echo
  echo "⚠ gh не установлен — тег отправлен, релиз нужно создать руками."
  echo
  echo "  brew install gh && gh auth login"
  echo "  gh release create $TAG \"$DMG\" \"$APPCAST\" --title \"GhostMeet $VERSION\" --notes-file \"$NOTES\""
  echo
  echo "  Либо через веб: Releases → Draft a new release → тег $TAG,"
  echo "  описание из $NOTES, приложить $DMG и $APPCAST"
  echo
  echo "  Лента обязательна: без неё установленные копии тихо не увидят версию."
fi

echo
echo "Тем, кто ставит GhostMeet впервые, вместе с файлом передайте одну команду —"
echo "без неё macOS откажется открывать приложение, потому что оно не нотаризовано:"
echo
echo "  xattr -dr com.apple.quarantine /Applications/GhostMeet.app"
echo
echo "На обновление она не нужна: приложение качает образ само, а карантин ставит"
echo "тот, кто скачивает, — браузер ставит, URLSession нет."
