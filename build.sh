#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="VoiceTuT.app"
INST="/Applications/VoiceTuT.app"
WHISPER_SRC="../voice-now/whisper.cpp/build_static/bin/whisper-cli"
MODEL_SRC="../voice-now/whisper.cpp/models/ggml-small.bin"
CERT_NAME="Voice2Dev"

echo "▶ 1/4  Компиляция..."
swift build 2>&1 | grep -E "(error:|Build complete)" | head -20
BIN=".build/debug/VoiceTuT"
[ -f "$BIN" ] || { echo "❌ Бинарь не найден"; exit 1; }

echo "▶ 2/4  Сборка .app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"        "$APP/Contents/MacOS/VoiceTuT"
cp "Sources/VoiceTuT/Info.plist" "$APP/Contents/Info.plist"

[ -f "$WHISPER_SRC" ] && cp "$WHISPER_SRC" "$APP/Contents/Resources/whisper-cli" \
    || { echo "❌ whisper-cli не найден: $WHISPER_SRC"; exit 1; }

[ -f "$MODEL_SRC" ] && cp "$MODEL_SRC" "$APP/Contents/Resources/ggml-small.bin" \
    || { echo "❌ Модель не найдена: $MODEL_SRC"; exit 1; }

echo "▶ 3/4  Подпись..."
# Выбираем identity: Voice2Dev (постоянный) или ad-hoc (временный)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    SIGN="$CERT_NAME"
    echo "  Сертификат: $CERT_NAME ✓ (разрешения сохранятся после пересборки)"
else
    SIGN="-"
    echo "  ⚠️  Сертификат '$CERT_NAME' не найден — используем ad-hoc подпись"
    echo "     Разрешения AX и Input Monitoring будут слетать при каждой сборке!"
    echo "     Один раз запусти: bash setup-cert.sh"
fi

# Desktop в iCloud Drive — система немедленно возвращает FinderInfo/fileprovider xattrs.
# Подписываем в /tmp, где iCloud не мешает, затем ставим оттуда.
ENTS="$(pwd)/VoiceTuT.entitlements"
TMP_APP="/tmp/VoiceTuT_sign.app"
rm -rf "$TMP_APP"
ditto "$APP" "$TMP_APP"
xattr -cr "$TMP_APP"
codesign --force --sign "$SIGN" --entitlements "$ENTS" "$TMP_APP"
APP="$TMP_APP"  # дальнейшие шаги используют подписанный бандл из /tmp

echo "▶ 4/4  Установка + запуск..."
pkill -x VoiceTuT 2>/dev/null || true
pkill -x Voice2 2>/dev/null || true   # на случай старого инстанса под прежним именем
sleep 0.5

# In-place обновление — НЕ удаляем весь бандл, чтобы macOS TCC
# не потерял записи о разрешениях, привязанных к пути приложения.
if [ -d "$INST" ]; then
    # ВАЖНО: имя исполняемого файла = CFBundleExecutable = VoiceTuT.
    # Раньше тут по ошибке писалось в .../MacOS/Voice2 — новый бинарь не доезжал.
    rm -f "$INST/Contents/MacOS/Voice2"  # вычищаем мусорный файл от прежних сборок
    cp "$APP/Contents/MacOS/VoiceTuT"  "$INST/Contents/MacOS/VoiceTuT"
    cp "$APP/Contents/Info.plist"    "$INST/Contents/Info.plist"
    # whisper-cli и модель: копируем только если их нет (они не меняются)
    [ -f "$INST/Contents/Resources/whisper-cli" ]   || cp "$APP/Contents/Resources/whisper-cli"  "$INST/Contents/Resources/whisper-cli"
    [ -f "$INST/Contents/Resources/ggml-small.bin" ] || cp "$APP/Contents/Resources/ggml-small.bin" "$INST/Contents/Resources/ggml-small.bin"
    # Переподписываем на месте (/Applications вне iCloud — xattr -cr безопасен)
    xattr -cr "$INST" 2>/dev/null || true
    codesign --force --sign "$SIGN" --entitlements "$ENTS" "$INST"
else
    cp -R "$APP" "$INST"
fi

open "$INST"
sleep 1.5
ps aux | grep "[V]oiceTuT" | grep -v grep | head -2 || echo "Процесс не найден"

echo ""
echo "✓  /Applications/VoiceTuT.app обновлён"
if [ "$SIGN" = "$CERT_NAME" ]; then
    echo "   Разрешения сохранены — повторно выдавать не нужно."
else
    echo ""
    echo "   Выдай разрешения (нужно т.к. ad-hoc подпись):"
    echo "   1. Нажми 'Выдать доступ к микрофону' в приложении"
    echo "   2. Настройки → Конфиденциальность → Универсальный доступ → + → VoiceTuT"
    echo "   3. Настройки → Конфиденциальность → Мониторинг ввода → + → VoiceTuT"
    echo "   4. Перезапусти VoiceTuT"
fi
