# 01 — Gatekeeper и права: два числа до всякого кода

**What to build:** Ничего. Тикет отвечает на два вопроса измерением, потому что без
ответов вся остальная фича проектируется по догадке.

**Вопрос первый: что делает Gatekeeper с подменённым бандлом, если приложение не
нотаризовано.** У проекта сертификат Apple Development, `spctl` такую сборку
отклоняет, и на первой установке это лечится ручным снятием карантина. Что
происходит, когда бандл в `/Applications` заменён **другим процессом**, а не
перетащен из образа, — предсказуемо не полностью, и гадать тут нечем.

Мерить обязательно **на чистой машине**: та, где приложение уже разрешено и уже
запускалось, ответит «всё хорошо» независимо от правды. Домашняя машина врёт ровно
в ту сторону, в которую нам хочется.

> **Уточнение, сделанное при замере.** Требование чистой машины было
> перестраховкой, и здесь оно мимо цели. Обновление **по определению** происходит
> там, где приложение уже установлено, уже запускалось и уже получило разрешения —
> то есть целевая среда этой фичи как раз «грязная», и мерить надо на ней. Чистая
> среда нужна для **первой** установки, а её эта фича не меняет: первая как была
> ручной, так и остаётся.
>
> Опасение, которое за этим стояло, верное и осталось в силе, но касается другого:
> **приложение, собранное в Xcode и запущенное из DerivedData, карантина не имеет
> никогда**, и система помнит его как разработческое. Поэтому всё ниже мерялось на
> копии, поставленной **из DMG в `/Applications`**, а не на сборке из DerivedData.
> Если понадобится среда, где приложение никогда не запускалось, второй Mac не
> нужен — достаточно **второй учётной записи macOS**: пользовательская часть TCC у
> неё своя.

**Вопрос второй: права на запись в `/Applications`.** У администратора обычно есть,
но «обычно» — не ответ, и поведение при их отсутствии это часть фичи, а не её край.
Проверить и случай, когда приложение лежит не в `/Applications`, а в `~/Applications`
или вообще в папке загрузок.

**Заодно проверить то, ради чего всё затевается:** что подменённое приложение
запускается **без** запроса разрешений заново. Ожидание — да: TCC привязан к
личности подписи, подпись та же. Ожидание не измерение; если оно не сбудется, фича
теряет смысл целиком, и узнать это надо здесь, а не после Sparkle.

**Как мерить.** Sparkle для этого не нужен: достаточно собрать две версии
`make-dmg.sh`, поставить первую, выдать ей разрешения, а вторую положить на место
первой скриптом — `ditto`/`mv` из процесса, запущенного от имени пользователя, — и
запустить. Это воспроизводит ровно то, что будет делать установщик.

**Что сдаётся:** запись в этой спеке с ответами и с тем, как их получили — на какой
версии macOS, на какой машине, каким способом подменяли. Числа без условий, при
которых они получены, в этом проекте не считаются измерением.

---

## Измерено

**Условия.** macOS 26.5 (сборка 25F71), Apple M5, arm64, машина владельца.
Gatekeeper включён:

```
$ spctl --status
assessments enabled
```

Установленное приложение — `/Applications/GhostMeet.app` версии **0.3.2** (сборка 5),
поставленное из DMG 15 августа и с тех пор запускавшееся: микрофон, захват звука и
запись экрана ему уже выданы. Подменяли **выпущенным образом 0.3.3** —
`dist/GhostMeet-0.3.3.dmg`, тот же файл, что лежит в релизе на GitHub
(sha256 `34e30f54…c50eee`). Подпись у обеих сборок одна:
`Apple Development: mihail@abrosk.in (TM76CW9JYD)`, `TeamIdentifier=Z6F3T2TJVB`.

### 1. Карантин: кто его ставит

Ставит его **тот, кто скачивает**, и только если объявил себя карантинящим. Образ
релиза, скачанный тремя способами, побайтово один и тот же, а карантин есть только
у браузерного:

```
$ curl -sSL -o probe-curl.dmg https://github.com/slimgo/ghostmeet/releases/download/v0.3.3/GhostMeet-0.3.3.dmg
$ xattr -l probe-curl.dmg
                                        ← пусто
```

`URLSession` — то, чем качает Sparkle, — ведёт себя так же:

```
$ ./urlsession-probe            # downloadTask(with:) на тот же URL
скачано: …/probe-urlsession.dmg
$ xattr -l probe-urlsession.dmg
                                        ← пусто
$ shasum -a 256 probe-curl.dmg probe-urlsession.dmg dist/GhostMeet-0.3.3.dmg
34e30f54…c50eee  probe-curl.dmg
34e30f54…c50eee  probe-urlsession.dmg
34e30f54…c50eee  dist/GhostMeet-0.3.3.dmg
```

Для контраста — файл, скачанный браузером:

```
$ xattr ~/Downloads/screen-inserts-00-12--00-50.mp4
com.apple.macl
com.apple.metadata:kMDItemWhereFroms
com.apple.provenance
com.apple.quarantine                    ← вот он
```

Приложение карантинит скачанное, если объявляет `LSFileQuarantineEnabled`. GhostMeet
не объявляет — ни в бандле, ни в исходном plist:

```
$ plutil -p /Applications/GhostMeet.app/Contents/Info.plist | grep -i LSFile
                                        ← ничего
```

**Вывод: `xattr -dr com.apple.quarantine` нужен на первую установку и не нужен на
обновление.** Выгода фичи подтверждается.

### 2. Gatekeeper при подмене бандла

`spctl` отклоняет сборку — ожидаемо, сертификат не Developer ID — и делает это
одинаково во всех трёх местах: на установленном 0.3.2, на образе и на распакованном:

```
$ spctl -a -vv /Applications/GhostMeet.app
/Applications/GhostMeet.app: rejected
origin=Apple Development: mihail@abrosk.in (TM76CW9JYD)
код возврата: 3
```

При этом подпись целая:

```
$ codesign --verify --deep --strict --verbose=2 /Applications/GhostMeet.app
GhostMeet.app: valid on disk
GhostMeet.app: satisfies its Designated Requirement
код возврата: 0
```

Подмена — `mv` из процесса пользователя, без `sudo`, ровно как сделает установщик
(старое в сторону, новое на место):

```
$ codesign -dv --verbose=4 /Applications/GhostMeet.app 2>&1 | grep ^CDHash
CDHash=26e7904c97ae4b3952cbeb3ba2c8d1123e058159      ← 0.3.2

$ mv /Applications/GhostMeet.app ./old-app;  echo $?      → 0
$ mv ./stage/GhostMeet.app /Applications/GhostMeet.app; echo $?  → 0

$ plutil -extract CFBundleShortVersionString raw -o - /Applications/GhostMeet.app/Contents/Info.plist
0.3.3
$ codesign -dv --verbose=4 /Applications/GhostMeet.app 2>&1 | grep ^CDHash
CDHash=aa3714260f842a6cc6eabcf18078c4fe56a803bc      ← другой бинарник
```

Запуск подменённого бандла:

```
$ open -a /Applications/GhostMeet.app;  echo $?          → 0
$ pgrep -lf GhostMeet
16051 /Applications/GhostMeet.app/Contents/MacOS/GhostMeet
```

**Gatekeeper не показал ничего и не был спрошен вовсе.** В логе `syspolicyd` за всё
время замера нет ни одной строки про GhostMeet. Причина не в везении: оценка
Gatekeeper запускается наличием карантина, а его нет — ни на скачанном образе, ни на
распакованном приложении, ни на подменённом бандле:

```
$ xattr -l /Applications/GhostMeet.app
com.apple.macl                          ← запись TCC о доступе к файлам, не карантин
```

Отсюда важное следствие, которое стоит держать в голове: **`spctl: rejected` и
«приложение не запустится» — разные вещи.** Первое было верно всё время и не
помешало ничему.

### 3. Разрешения: спрашивает ли macOS заново

Не спрашивает. Механизм виден прямо в базе TCC: она хранит не версию и не хеш, а
**требование к коду**, и оно совпадает с designated requirement бандла дословно:

```
$ sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
    "select hex(csreq) from access where client='Mixxy.GhostMeet' and service='kTCCServiceMicrophone';" \
    | xxd -r -p > mic-csreq.bin
$ csreq -r mic-csreq.bin -t
identifier "Mixxy.GhostMeet" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: mihail@abrosk.in (TM76CW9JYD)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

Ни версии, ни CDHash в требовании нет — только идентификатор бандла и сертификат.
Подменённый 0.3.3 ему удовлетворяет:

```
$ codesign --verify -R="$(csreq -r mic-csreq.bin -t)" --verbose=2 /Applications/GhostMeet.app
/Applications/GhostMeet.app: valid on disk
/Applications/GhostMeet.app: satisfies its Designated Requirement
/Applications/GhostMeet.app: explicit requirement satisfied
код возврата: 0
```

Это не рассуждение, а то же самое, что делает `tccd`. Живой прогон подменённой
0.3.3 — запуск и включение прослушивания аккордом ⌥⌘L, с `log stream` рядом:

```
$ /usr/bin/log stream --style compact --level debug \
    --predicate 'process == "tccd" AND eventMessage CONTAINS "GhostMeet"'

tccd  -[TCCDAccessIdentity matchesCodeRequirement:]: SecStaticCodeCheckValidity()
      static code from Mixxy.GhostMeet : identifier "Mixxy.GhostMeet" and anchor apple
      generic and certificate leaf[subject.CN] = "Apple Development: mihail@abrosk.in
      (TM76CW9JYD)" and certificate 1[…]; status: 0

tccd  Handling access request to kTCCServiceMicrophone, from Sub:{Mixxy.GhostMeet}
      Resp:{… binary_path=/Applications/GhostMeet.app/Contents/MacOS/GhostMeet},
      ReqResult(Auth Right: Allowed (User Consent), promptType: 1, DB Action:None)

tccd  Handling access request to kTCCServiceScreenCapture, from Sub:{Mixxy.GhostMeet}
      Resp:{… binary_path=/Applications/GhostMeet.app/Contents/MacOS/GhostMeet},
      ReqResult(Auth Right: Allowed (System Set), promptType: 1, DB Action:None)
```

Сводка по всем решениям за прогон:

```
   1 kTCCServiceMicrophone                → Auth Right: Allowed (User Consent)
   7 kTCCServiceScreenCapture             → Auth Right: Allowed (System Set)
   1 kTCCServiceSystemPolicyDocumentsFolder → Auth Right: Allowed (User Consent)
  14 DB Action:None                       ← все четырнадцать, ни одной записи в базу
   0 строк со словом PROMPT                ← пользователя не спросили ни разу
```

`DB Action:None` — это и есть ответ: новая запись не появилась, старая не изменилась,
диалога не было. Сверка базы до и после подмены даёт то же самое — `last_modified`
у обеих строк остались прежними (микрофон 2026-08-05, захват звука 2026-08-15).

**Захват экрана попал в замер живьём**, и это важно отдельно: он живёт в *системной*
базе TCC, читать которую без пароля нечем, — а лог `tccd` показал её решение прямо.

### 4. Права на запись и место установки

`/Applications` пишется группой `admin`, и владелец в ней:

```
$ ls -ld /Applications
drwxrwxr-x  106 root  admin  3392 Aug 15 18:42 /Applications
$ id -Gn | tr ' ' '\n' | grep -x admin
admin
$ ls -ld /Applications/GhostMeet.app
drwxr-xr-x  3 mikhailabroskin  admin  96 /Applications/GhostMeet.app
```

Отсюда прямо читается и случай, который на этой машине не воспроизвести: **у
обычной (не администраторской) учётной записи права нет** — она не в группе
`admin`, а прочим дана только `r-x`.

Что происходит без права на запись — воспроизведено на каталоге со снятым битом:

```
$ chmod a-w nowrite
$ ditto "…/GhostMeet.app" nowrite/GhostMeet-new.app
ditto: nowrite/GhostMeet-new.app: Permission denied
$ mv nowrite/GhostMeet.app nowrite/GhostMeet-old.app
mv: rename …: Permission denied
```

Отказ чистый и **старый бандл остаётся целым** — то самое «сбой обновления оставляет
рабочее приложение», на уровне файловой системы.

**Но Sparkle на этом не останавливается, и это находка для тикета 04.** В
`InstallerLauncher/SUInstallerLauncher.m` (2.9.6) он сам проверяет записываемость и
при отказе **эскалирует права системным диалогом**:

```objc
BOOL SPUSystemNeedsAuthorizationAccessForBundlePath(NSString *bundlePath) {
    BOOL hasWritability = [fileManager isWritableFileAtPath:bundlePath]
        && [fileManager isWritableFileAtPath:[bundlePath stringByDeletingLastPathComponent]];
    if (!hasWritability) { needsAuthorization = YES; }
    …
}
```

```objc
authorizationPrompt = [NSString stringWithFormat:@"%1$@ wants permission to update.", hostName];
… AuthorizationRightSet(auth, rightName, @(kAuthorizationRuleAuthenticateAsAdmin), …)
… AuthorizationFlags flags = kAuthorizationFlagExtendRights | kAuthorizationFlagInteractionAllowed;
```

Это **окно за пределами нашего окна**, с запросом пароля, — ровно то, что запрещает
[ADR-0004](../../../docs/adr/0004-invisibility-scope.md). Проверять записываемость
надо самим и тем же условием, до того как установка начата, и отказывать в своём
окне; в тикет 04 это внесено.

**Место установки роли не играет.** Тот же бандл, запущенный из `~/Applications`:

```
$ pgrep -lf GhostMeet.app/Contents/MacOS
97937 /Users/mikhailabroskin/Applications/GhostMeet.app/Contents/MacOS/GhostMeet

   1 kTCCServiceMicrophone     → Auth Right: Allowed (User Consent)
   7 kTCCServiceScreenCapture  → Auth Right: Allowed (System Set)
```

Разрешения действуют и там — в требовании TCC пути нет, только идентификатор и
сертификат. `~/Applications` при этом `drwx------` и принадлежит пользователю, то
есть пишется всегда и эскалации не потребует никогда.

### 5. Заодно: примет ли Sparkle наш образ

Вопрос из спеки, на который «наверное, подойдёт» не годится, — отвечен чтением
`Autoupdate/SUDiskImageUnarchiver.m` (2.9.6), а не догадкой. Распаковщик обходит
корень тома и отбирает так:

```objc
if ([lastPathComponent hasPrefix:@"."]) { continue; }              // скрытые
if (… NSURLIsAliasFileKey …) { continue; }                          // алиасы
if (… NSURLIsSymbolicLinkKey …) { continue; }                       // симлинки
if (isDirectory) { if ([pathExtension isEqualToString:@"rtfd"]) continue; }
else { if (![pathExtension isEqualToString:@"pkg"] && ![pathExtension isEqualToString:@"mpkg"]) continue; }
```

Содержимое образа, который делает `make-dmg.sh`:

```
$ ls -la "/Volumes/GhostMeet 0.3.3"
drwxr-xr-x  GhostMeet.app                    ← каталог, не .rtfd → берётся
lrwxr-xr-x  Программы -> /Applications       ← симлинк           → пропускается
-rw-r--r--  ЧИТАТЬ ПЕРВЫМ.txt                ← не .pkg           → пропускается
```

**Существующий образ подходит как есть, отдельный ZIP не нужен.** Ярлык «Программы»
и инструкция Sparkle не заденут, а из образа он возьмёт ровно `GhostMeet.app`.

### Чего проверить было нечем

- **Системная база TCC** (`/Library/Application Support/com.apple.TCC/TCC.db`) не
  читалась: нужен пароль, `sudo -n` отказал. Решение по захвату экрана взято из лога
  `tccd`, что для этого вопроса даже прямее — там видно само решение, а не запись.
- **Не администраторская учётная запись** не проверялась запуском: на этой машине её
  нет. Вывод про неё сделан из битов доступа `/Applications`, и это утверждение о
  правах POSIX, а не наблюдение.
- **Первая установка** (образ, скачанный браузером, с карантином) не перемерялась:
  эта фича её не меняет, а поведение известно и записано в `dmg-readme.txt`.

### Что это значит для фичи

Ни одно из измерений её не отменяет, а главное — подтверждает: **обновление,
поставленное самим приложением, карантина не получает, и разрешения переживают
подмену.** То есть выгода, ради которой всё затевалось, реальна.

К переносу в тикеты дальше: Sparkle без прав на запись показывает системный диалог
(→ 04), а образ `make-dmg.sh` годится как есть (→ 02).

---

**Acceptance:**
- сказано, показывает ли Gatekeeper что-либо при запуске подменённого бандла, и
  что именно;
- сказано, снимается ли карантин с того, что скачало и распаковало само
  приложение;
- сказано, спрашивает ли macOS микрофон и запись экрана заново;
- названо поведение при отсутствии прав на запись и при установке вне
  `/Applications`;
- условия замера записаны рядом с результатами.

**Читать:** [спека](../spec.md) · [releasing.md](../../../docs/releasing.md), разделы про подпись и нотаризацию · [audio-traps.md](../../../docs/audio-traps.md), раздел «Разрешения и TCC»

**Blocked by:** None.

**Status:** done
