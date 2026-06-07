# Voice2 — Windows build & install
# Аналог build.sh, делает то же самое на Windows:
#   1. Проверяет инструменты (.NET 8 SDK, Inno Setup)
#   2. dotnet publish → один self-contained .exe
#   3. Копирует whisper.exe + модель + иконку в dist\
#   4. Опционально подписывает signtool'ом (если есть сертификат в Cert:\CurrentUser\My)
#   5. Запаковывает в Voice2-Setup-X.Y.Z.exe через Inno Setup
#   6. Опционально ставит локально (-InstallLocal) и запускает
#
# Запуск (из voice2/):
#   .\build.ps1                  # сборка
#   .\build.ps1 -InstallLocal    # сборка + локальная установка + запуск
#   .\build.ps1 -SkipInstaller   # только Voice2.exe, без Inno Setup

[CmdletBinding()]
param(
    [string]$Version = "2.1.0",
    [string]$CertSubject = "Voice2Dev",
    [switch]$InstallLocal,
    [switch]$SkipInstaller,
    [switch]$SkipSign
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$ROOT       = $PSScriptRoot
$SRC        = Join-Path $ROOT "src-win"
$RESOURCES  = Join-Path $ROOT "resources"
$INSTALLER  = Join-Path $ROOT "installer"
$DIST       = Join-Path $ROOT "dist"
$APP_NAME   = "Voice2"
$EXE_NAME   = "Voice2.exe"
$INSTALL_DIR = Join-Path $env:LOCALAPPDATA $APP_NAME

function Write-Step($msg) { Write-Host ""; Write-Host "▶ $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "  ✗ $msg" -ForegroundColor Red; exit 1 }

# ───────────────────────────────────────────────────────────────
# 1/6  Проверка инструментов
# ───────────────────────────────────────────────────────────────
Write-Step "1/6  Проверка инструментов"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Fail ".NET SDK не найден. Установи: winget install Microsoft.DotNet.SDK.8"
}
$dotnetVer = (dotnet --version) 2>$null
Write-OK ".NET SDK $dotnetVer"

if (-not $SkipInstaller) {
    $iscc = Get-Command iscc -ErrorAction SilentlyContinue
    if (-not $iscc) {
        $isccPath = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
        if (Test-Path $isccPath) { $iscc = $isccPath } else {
            Write-Warn "Inno Setup не найден — пропускаю упаковку. Установи: winget install JRSoftware.InnoSetup"
            $SkipInstaller = $true
        }
    } else { $iscc = $iscc.Source }
    if (-not $SkipInstaller) { Write-OK "Inno Setup: $iscc" }
}

if (-not $SkipSign) {
    $signtool = Get-Command signtool -ErrorAction SilentlyContinue
    if (-not $signtool) {
        $signPath = (Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -match 'x64' } | Select-Object -First 1).FullName
        if ($signPath) { $signtool = $signPath } else {
            Write-Warn "signtool.exe не найден — пропускаю подпись"
            $SkipSign = $true
        }
    } else { $signtool = $signtool.Source }
}

# ───────────────────────────────────────────────────────────────
# 2/6  Проверка ресурсов (whisper.exe + модель)
# ───────────────────────────────────────────────────────────────
Write-Step "2/6  Проверка ресурсов"

$whisperExe   = Join-Path $RESOURCES "whisper.exe"
$whisperModel = Join-Path $RESOURCES "ggml-base.bin"
$iconFile     = Join-Path $RESOURCES "voice2.ico"

if (-not (Test-Path $whisperExe))   { Write-Fail "Нет $whisperExe — пересобери whisper.cpp под Windows MSVC и положи сюда" }
if (-not (Test-Path $whisperModel)) { Write-Fail "Нет $whisperModel — скачай: huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-base.bin" }
if (-not (Test-Path $iconFile))     { Write-Warn "Нет $iconFile — будет дефолтная WPF-иконка" }
Write-OK "Ресурсы на месте"

# ───────────────────────────────────────────────────────────────
# 3/6  Компиляция (dotnet publish self-contained)
# ───────────────────────────────────────────────────────────────
Write-Step "3/6  Компиляция Voice2.exe"

if (-not (Test-Path $SRC)) {
    Write-Warn "Папка src-win\ ещё не создана — пропускаю компиляцию."
    Write-Warn "Создай $SRC\Voice2.csproj и запусти .\build.ps1 повторно."
    Write-Host ""
    Write-Host "Следующий шаг: распакуй WPF-скелет в $SRC и запусти .\build.ps1 ещё раз." -ForegroundColor Yellow
    exit 0
}

if (Test-Path $DIST) { Remove-Item $DIST -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DIST | Out-Null

Push-Location $SRC
try {
    dotnet publish Voice2.csproj `
        -c Release `
        -r win-x64 `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:Version=$Version `
        -o "$DIST" `
        | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Fail "dotnet publish упал" }
} finally { Pop-Location }

$mainExe = Join-Path $DIST $EXE_NAME
if (-not (Test-Path $mainExe)) { Write-Fail "Не нашёл $mainExe после publish" }
Write-OK "Voice2.exe собран ($([math]::Round((Get-Item $mainExe).Length / 1MB, 1)) MB)"

# ───────────────────────────────────────────────────────────────
# 4/6  Копирование ресурсов
# ───────────────────────────────────────────────────────────────
Write-Step "4/6  Копирование ресурсов в dist\"

Copy-Item $whisperExe   (Join-Path $DIST "whisper.exe")     -Force
Copy-Item $whisperModel (Join-Path $DIST "ggml-base.bin")   -Force
if (Test-Path $iconFile) { Copy-Item $iconFile (Join-Path $DIST "voice2.ico") -Force }
Write-OK "whisper.exe + модель + иконка"

# ───────────────────────────────────────────────────────────────
# 5/6  Подпись (если есть сертификат)
# ───────────────────────────────────────────────────────────────
if (-not $SkipSign) {
    Write-Step "5/6  Подпись бинарей"
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -match $CertSubject } | Select-Object -First 1
    if ($cert) {
        & $signtool sign /sm /sha1 $cert.Thumbprint /tr "http://timestamp.digicert.com" /td sha256 /fd sha256 $mainExe | Out-Null
        Write-OK "Подписано сертификатом '$CertSubject'"
    } else {
        Write-Warn "Сертификат '$CertSubject' не найден — exe идёт без подписи (SmartScreen будет ругаться)"
    }
} else {
    Write-Step "5/6  Подпись — пропущено"
}

# ───────────────────────────────────────────────────────────────
# 6/6  Inno Setup (упаковка в Setup.exe)
# ───────────────────────────────────────────────────────────────
if (-not $SkipInstaller) {
    Write-Step "6/6  Упаковка Voice2-Setup-$Version.exe"

    $issFile = Join-Path $INSTALLER "Voice2.iss"
    if (-not (Test-Path $issFile)) {
        Write-Warn "Нет $issFile — пропускаю упаковку"
    } else {
        & $iscc "/DAppVersion=$Version" "/O$DIST" $issFile | Out-Host
        $setupExe = Join-Path $DIST "Voice2-Setup-$Version.exe"
        if (Test-Path $setupExe) {
            if (-not $SkipSign -and $cert) {
                & $signtool sign /sm /sha1 $cert.Thumbprint /tr "http://timestamp.digicert.com" /td sha256 /fd sha256 $setupExe | Out-Null
            }
            Write-OK "Voice2-Setup-$Version.exe готов ($([math]::Round((Get-Item $setupExe).Length / 1MB, 1)) MB)"
        } else {
            Write-Warn "Inno Setup отработал, но Setup.exe не найден в $DIST"
        }
    }
} else {
    Write-Step "6/6  Упаковка — пропущено"
}

# ───────────────────────────────────────────────────────────────
# Локальная установка (опционально)
# ───────────────────────────────────────────────────────────────
if ($InstallLocal) {
    Write-Step "Локальная установка в $INSTALL_DIR"

    Get-Process -Name $APP_NAME -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    if (-not (Test-Path $INSTALL_DIR)) { New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null }
    Copy-Item (Join-Path $DIST "*") -Destination $INSTALL_DIR -Recurse -Force
    Write-OK "Файлы скопированы"

    # Ярлык на рабочем столе
    $shell = New-Object -ComObject WScript.Shell
    $desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "$APP_NAME.lnk"
    $lnk = $shell.CreateShortcut($desktopLnk)
    $lnk.TargetPath = Join-Path $INSTALL_DIR $EXE_NAME
    $lnk.IconLocation = Join-Path $INSTALL_DIR "voice2.ico"
    $lnk.Save()
    Write-OK "Ярлык на рабочем столе"

    # Автозапуск
    $startupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "$APP_NAME.lnk"
    $lnk = $shell.CreateShortcut($startupLnk)
    $lnk.TargetPath = Join-Path $INSTALL_DIR $EXE_NAME
    $lnk.Arguments = "--minimized"
    $lnk.Save()
    Write-OK "Автозапуск настроен"

    Start-Process (Join-Path $INSTALL_DIR $EXE_NAME)
    Write-OK "Voice2 запущен"
}

Write-Host ""
Write-Host "Готово!" -ForegroundColor Green
Write-Host "  dist\Voice2.exe                  — основной бинарь"
if (-not $SkipInstaller) {
    Write-Host "  dist\Voice2-Setup-$Version.exe   — установщик для раздачи"
}
if (-not $InstallLocal) {
    Write-Host ""
    Write-Host "Для локальной установки: .\build.ps1 -InstallLocal"
}
