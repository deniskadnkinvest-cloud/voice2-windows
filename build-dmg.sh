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
