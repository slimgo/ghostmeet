#!/bin/bash
#
# Собирает GhostMeet.app в Release и упаковывает в DMG для передачи коллегам.
#
#   ./scripts/make-dmg.sh            # версия из проекта
#   ./scripts/make-dmg.sh 1.0-beta2  # своя метка версии в имени файла
#
# Готовый образ кладётся в dist/. Внутри — приложение, ярлык «Программы» и
# файл с инструкцией: без неё коллега получит «программу нельзя открыть» и
# решит, что сборка битая.
#
# Почему без нотаризации. У проекта есть только сертификат Apple Development —
# нотаризация требует Developer ID, то есть платного участия в Apple Developer
# Program. Подпись при этом настоящая и стабильная, и это
# важнее, чем кажется: разрешения macOS привязаны к подписи, и при ad-hoc
# подписи каждая новая сборка спрашивала бы микрофон и запись экрана заново.
# Цена — карантин: смотри инструкцию, которую скрипт кладёт внутрь образа.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
PROJECT="$ROOT/GhostMeet/GhostMeet.xcodeproj"
DERIVED="$ROOT/.build/dmg-derived"
STAGE="$ROOT/.build/dmg-stage"
DIST="$ROOT/dist"

VERSION="${1:-$(xcodebuild -project "$PROJECT" -showBuildSettings -target GhostMeet 2>/dev/null \
  | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}')}"
DMG="$DIST/GhostMeet-$VERSION.dmg"

echo "▸ Сборка Release…"
rm -rf "$DERIVED" "$STAGE"
xcodebuild -project "$PROJECT" -scheme GhostMeet -configuration Release \
  -derivedDataPath "$DERIVED" build >/dev/null

APP="$DERIVED/Build/Products/Release/GhostMeet.app"
[ -d "$APP" ] || { echo "✗ Сборка не дала GhostMeet.app"; exit 1; }

echo "▸ Проверка подписи…"
codesign --verify --deep --strict "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier" | sed 's/^/  /'

# Designated requirement — это то, по чему TCC узнаёт приложение: не версия и не
# хеш, а идентификатор бандла плюс сертификат. Пока он тот же, обновление
# сохраняет микрофон и запись экрана; сменись он — и каждая установленная копия
# при первом же обновлении спросит разрешения заново, а пользователь решит, что
# сборка сломана. Ad-hoc-подпись даёт требование по cdhash, то есть своё на
# каждую сборку, и ловится здесь.
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
case "$REQUIREMENT" in
  *"Apple Development: "*) echo "  requirement тот же, что у прошлых сборок" ;;
  *) echo "✗ Designated requirement не от Apple Development:"
     echo "    ${REQUIREMENT:-пусто}"
     echo "  Такая сборка заново спросит микрофон и запись экрана у всех, кто обновится."
     exit 1 ;;
esac

# Пустой Info.plist ловится здесь, а не у коллеги: строки разрешений в этом
# проекте уже пропадали молча — Xcode выкидывает неизвестные ему INFOPLIST_KEY_*
# без единого предупреждения, и приложение доезжает без доступа к экрану.
echo "▸ Проверка строк разрешений…"
for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription \
           NSScreenCaptureUsageDescription NSSpeechRecognitionUsageDescription; do
  plutil -extract "$key" raw -o - "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || { echo "✗ В Info.plist нет $key — приложение молча останется без доступа"; exit 1; }
done
echo "  все четыре на месте"

# Та же ловушка, что и выше, но дороже. Без SUPublicEDKey приложению нечем
# проверить подпись обновления, а generate_appcast в этом случае отдаёт
# неподписанную ленту молча и с кодом 0 — он подписывает, только если нашёл
# этот ключ в бандле. Двойная тишина: ключ пропал без предупреждения, лента
# вышла без подписи без предупреждения, и узналось бы это на машине
# пользователя. Проверяется здесь, в собранном бандле.
echo "▸ Проверка ключей Sparkle…"
for key in SUFeedURL SUPublicEDKey; do
  value="$(plutil -extract "$key" raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" \
    || { echo "✗ В Info.plist нет $key — обновление сломано (см. CLAUDE.md про INFOPLIST_KEY_*)"; exit 1; }
  [ -n "$value" ] \
    || { echo "✗ $key в Info.plist пустой"; exit 1; }
done

# Обещание «наружу уходит IP и версия и больше ничего» проверяется, а не
# подразумевается. Гейтит отправку профиля SUSendProfileInfo; SUEnableSystemProfiling
# заведён рядом, чтобы задокументированный ключ не обещал обратного.
for key in SUSendProfileInfo SUEnableSystemProfiling SUEnableAutomaticChecks; do
  value="$(plutil -extract "$key" raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" \
    || { echo "✗ В Info.plist нет $key"; exit 1; }
  [ "$value" = "false" ] \
    || { echo "✗ $key в Info.plist = $value, а должен быть false"; exit 1; }
done
echo "  лента, открытый ключ и три запрета на месте"

# Английская таблица строк — такой же молча пропадающий ресурс, как ключи выше:
# каталог, не попавший в сборку, даёт приложение, которое просто целиком
# по-русски, без единой ошибки. Заметит это англоязычный пользователь.
echo "▸ Проверка перевода…"
# Сначала исходники: строка, которую забыли обернуть, в каталог не попадает
# вовсе — и проверка по бандлу её не увидит, потому что искать в бандле нечего.
"$ROOT/scripts/find-untranslated.sh"
STRINGS="$APP/Contents/Resources/en.lproj/Localizable.strings"
[ -f "$STRINGS" ] \
  || { echo "✗ В бандле нет en.lproj/Localizable.strings — английского в приложении нет"; exit 1; }
PHRASES="$(plutil -p "$STRINGS" 2>/dev/null | grep -c "=>" || echo 0)"
[ "$PHRASES" -gt 200 ] \
  || { echo "✗ В английской таблице всего $PHRASES строк — каталог доехал не целиком"; exit 1; }
echo "  английских строк: $PHRASES"

echo "▸ Сборка образа…"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"
cp "$ROOT/scripts/dmg-readme.txt" "$STAGE/ЧИТАТЬ ПЕРВЫМ.txt"

rm -f "$DMG"
hdiutil create -volname "GhostMeet $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

echo
echo "✓ $DMG"
echo "  $(du -h "$DMG" | cut -f1), версия $VERSION"
echo
echo "Коллеге вместе с файлом передайте одну команду — без неё macOS откажется"
echo "открывать приложение, потому что оно не нотаризовано:"
echo
echo "  xattr -dr com.apple.quarantine /Applications/GhostMeet.app"
