#!/bin/bash
#
# Ставит версию в проекте перед релизом.
#
#   ./scripts/set-version.sh 0.2.0
#
# Меняет MARKETING_VERSION во всех четырёх конфигурациях (два таргета × Debug/Release) и
# увеличивает CURRENT_PROJECT_VERSION на единицу. Правки остаются незакоммиченными: сначала
# допишите раздел в CHANGELOG.md, потом коммит, и только потом ./scripts/release.sh.
#
# Версия живёт в pbxproj, а не в отдельном xcconfig, сознательно: xcconfig пришлось бы вносить в
# файл проекта руками, а pbxproj в этом проекте и так единственное место, которое правится руками.

set -euo pipefail

cd "$(dirname "$0")/.."
PBXPROJ="GhostMeet/GhostMeet.xcodeproj/project.pbxproj"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "✗ Укажите версию: ./scripts/set-version.sh 0.2.0"; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "✗ Версия должна быть MAJOR.MINOR.PATCH, а не «$VERSION»"; exit 1; }

OLD="$(grep -m1 -oE 'MARKETING_VERSION = [^;]+' "$PBXPROJ" | cut -d' ' -f3)"
BUILD="$(grep -m1 -oE 'CURRENT_PROJECT_VERSION = [0-9]+' "$PBXPROJ" | grep -oE '[0-9]+$')"
NEXT_BUILD=$((BUILD + 1))

sed -i '' \
  -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" \
  -e "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" \
  "$PBXPROJ"

# Битый pbxproj Xcode откроет, а xcodebuild — нет, и выяснится это на сборке релиза.
plutil -lint "$PBXPROJ" >/dev/null || { echo "✗ pbxproj после правки не читается"; exit 1; }

COUNT="$(grep -c "MARKETING_VERSION = $VERSION;" "$PBXPROJ")"
[ "$COUNT" -eq 4 ] || { echo "✗ MARKETING_VERSION проставлен в $COUNT местах из четырёх"; exit 1; }

echo "✓ $OLD → $VERSION, сборка $BUILD → $NEXT_BUILD"
echo
echo "Дальше:"
echo "  1. допишите раздел ## [$VERSION] в CHANGELOG.md"
# Строка английская не по вкусу, а по правилу из CLAUDE.md: репозиторий
# публичный, историю читают по той же ссылке, что и README. Русская подсказка
# стояла здесь до 0.5.2 и вышла четырьмя русскими заголовками подряд — её
# копировали, не сверяясь с правилом. Отклоняет такой заголовок .githooks/commit-msg.
echo "  2. git commit -am \"Version $VERSION\""
echo "  3. ./scripts/release.sh $VERSION"
