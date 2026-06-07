#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# ─────────────────────────────────────────────────────────────────────────────
# Сборка компактного DMG-инсталлятора VoiceTuT для распространения на MacBook.
#
# Ключевое отличие от build.sh: модель Whisper (ggml-*.bin, 465 MB – 3 GB) НЕ
# кладётся в бандл. .app остаётся маленьким (~6 MB), а модель скачивается при
# первом запуске через онбординг (ModelManager → HuggingFace). Так DMG весит
# единицы мегабайт вместо полугигабайта.
#
# Итог: VoiceTuT-Installer.dmg в корне проекта — перетащил .app в Applications,
# открыл, выбрал модель, она докачалась. Хоткей по умолчанию — Fn.
# ─────────────────────────────────────────────────────────────────────────────

APP="VoiceTuT.app"
WHISPER_SRC="../voice-now/whisper.cpp/build_static/bin/whisper-cli"
CERT_NAME="Voice2Dev"
ENTS="$(pwd)/VoiceTuT.entitlements"
DMG_OUT="$(pwd)/VoiceTuT-Installer.dmg"
VOLNAME="VoiceTuT"

echo "▶ 1/5  Компиляция (release)..."
if swift build -c release 2>&1 | grep -E "(error:|Build complete)" | head -20; then :; fi
BIN=".build/release/VoiceTuT"
if [ ! -f "$BIN" ]; then
    echo "  release не собрался — пробую debug..."
    swift build 2>&1 | grep -E "(error:|Build complete)" | head -20
    BIN=".build/debug/VoiceTuT"
fi
[ -f "$BIN" ] || { echo "❌ Бинарь не найден"; exit 1; }

echo "▶ 2/5  Сборка .app (без модели — она докачается на первом запуске)..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"                          "$APP/Contents/MacOS/VoiceTuT"
cp "Sources/VoiceTuT/Info.plist"   "$APP/Contents/Info.plist"

# whisper-cli обязателен (он сам по себе ~3 MB, линкуется только на системные фреймворки).
if [ -f "$WHISPER_SRC" ]; then
    cp "$WHISPER_SRC" "$APP/Contents/Resources/whisper-cli"
elif [ -f "/Applications/VoiceTuT.app/Contents/Resources/whisper-cli" ]; then
    cp "/Applications/VoiceTuT.app/Contents/Resources/whisper-cli" "$APP/Contents/Resources/whisper-cli"
else
    echo "❌ whisper-cli не найден ни в $WHISPER_SRC, ни в установленном .app"; exit 1
fi

echo "▶ 3/5  Подпись..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    SIGN="$CERT_NAME"
    echo "  Сертификат: $CERT_NAME ✓"
else
    SIGN="-"
    echo "  ⚠️  $CERT_NAME не найден — ad-hoc подпись (Gatekeeper потребует ручного открытия)"
fi

# Desktop в iCloud Drive подкидывает xattrs и ломает codesign — собираем в /tmp.
TMP_APP="/tmp/VoiceTuT_dmg.app"
rm -rf "$TMP_APP"
ditto "$APP" "$TMP_APP"
xattr -cr "$TMP_APP"
# Подписываем изнутри наружу: сперва вложенный whisper-cli, затем сам бандл.
codesign --force --sign "$SIGN" "$TMP_APP/Contents/Resources/whisper-cli"
codesign --force --sign "$SIGN" --entitlements "$ENTS" "$TMP_APP"
codesign --verify --deep --strict "$TMP_APP" 2>&1 | head -5 || true

echo "▶ 4/5  Сборка staging для DMG..."
STAGE="/tmp/VoiceTuT_dmg_stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$TMP_APP" "$STAGE/VoiceTuT.app"
ln -s /Applications "$STAGE/Applications"   # перетащить мышкой в Программы

# Приложение self-signed без нотаризации → на ЧУЖОМ маке Gatekeeper его блокирует
# (generic «Не удаётся открыть программу»). Кладём в образ установщик и инструкцию,
# которые снимают карантин и тем самым разрешают запуск.
cat > "$STAGE/Установить VoiceTuT.command" <<'CMD'
#!/bin/bash
# Двойной клик ставит VoiceTuT в «Программы» в обход Gatekeeper.
# Если macOS не даёт открыть этот файл — ПКМ по нему → «Открыть».
set -e
SRC="$(cd "$(dirname "$0")" && pwd)/VoiceTuT.app"
DEST="/Applications/VoiceTuT.app"
echo "→ Копирую VoiceTuT в «Программы»…"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "→ Снимаю карантин…"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "→ Запускаю…"
open "$DEST"
echo "Готово. Хоткей по умолчанию — Fn."
CMD
chmod +x "$STAGE/Установить VoiceTuT.command"

cat > "$STAGE/КАК ОТКРЫТЬ — прочти.txt" <<'TXT'
VoiceTuT — установка на macOS
=============================

Приложение подписано локально (self-signed) и НЕ нотаризовано в Apple,
поэтому на чужом маке macOS по умолчанию блокирует первый запуск
(«Не удаётся открыть программу VoiceTuT»). Это нормально. Обход — разовый.

СПОСОБ 1 (проще всего):
  • Двойной клик по «Установить VoiceTuT.command».
  • Если сам .command не открывается — ПКМ по нему → «Открыть» → «Открыть».

СПОСОБ 2 (вручную):
  1. Перетащи VoiceTuT.app в «Программы».
  2. Открой Терминал (Spotlight → «Терминал») и выполни одной строкой:
        xattr -dr com.apple.quarantine /Applications/VoiceTuT.app
  3. Запусти VoiceTuT из «Программ».

СПОСОБ 3 (через настройки):
  1. Перетащи VoiceTuT.app в «Программы», попробуй открыть (получишь ошибку).
  2. Системные настройки → «Конфиденциальность и безопасность» →
     внизу строка про VoiceTuT → «Открыть всё равно» → пароль.

После первого запуска:
  • Онбординг предложит скачать модель распознавания.
  • Выдай доступ к Микрофону и к «Мониторингу ввода» (для хоткея).
  • Хоткей по умолчанию — Fn: зажми Fn → говори → отпусти.
TXT

echo "▶ 5/5  Создание сжатого DMG..."
rm -f "$DMG_OUT"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_OUT" >/dev/null

# Прибираем за собой.
rm -rf "$TMP_APP" "$STAGE"

echo ""
echo "✓  Готов: $DMG_OUT"
echo "   Размер: $(du -h "$DMG_OUT" | cut -f1)"
echo "   .app внутри: $(du -sh "$APP" | cut -f1) (без модели)"
echo ""
echo "Установка на MacBook:"
echo "   1. Открой DMG → перетащи VoiceTuT в «Программы»"
echo "   2. Первый запуск: ПКМ → «Открыть» (подпись self-signed, не нотаризована)"
echo "   3. Онбординг предложит скачать модель распознавания"
echo "   4. Хоткей по умолчанию — Fn. Зажми Fn → говори → отпусти."
