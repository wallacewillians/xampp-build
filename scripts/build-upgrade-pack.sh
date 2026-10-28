#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
OS="${2:-windows-x64}"

if [ -z "$VERSION" ]; then
    echo "Erro: Versao nao informada. Exemplo: bash build-upgrade-pack.sh 83 windows-x64"
    exit 1
fi

if [ "$OS" != "windows-x64" ]; then
    echo "Upgrade pack disponivel apenas para windows-x64. Ignorando para $OS."
    exit 0
fi

echo "========================================================"
echo "Gerando Pacote de Upgrade do PHP $VERSION para $OS..."
echo "========================================================"

# Extrair formato maior.menor (ex: 82 -> 8.2, 83 -> 8.3, 84 -> 8.4)
MAJOR="${VERSION:0:1}"
MINOR="${VERSION:1:1}"
PHP_SERIES="${MAJOR}.${MINOR}"

# Localizar o arquivo zip correspondente em /tmp/tarballs
PHP_ZIP=$(find /tmp/tarballs/ -name "php-${PHP_SERIES}.*-x64.zip" 2>/dev/null | head -n 1)

if [ -z "$PHP_ZIP" ] || [ ! -f "$PHP_ZIP" ]; then
    echo "Procurando arquivo correspondente a PHP $PHP_SERIES..."
    PHP_ZIP=$(find /tmp/tarballs/ -name "php-*.zip" 2>/dev/null | grep -E "php-${PHP_SERIES}" | head -n 1 || true)
fi

if [ -z "$PHP_ZIP" ] || [ ! -f "$PHP_ZIP" ]; then
    echo "Erro: Nao foi possivel encontrar o binario compactado do PHP para a versao $VERSION ($PHP_SERIES)."
    exit 1
fi

echo "Arquivo base localizado: $PHP_ZIP"

UPGRADE_DIR="/tmp/xampp-php${VERSION}-upgrade-pack"
rm -rf "$UPGRADE_DIR"
mkdir -p "$UPGRADE_DIR/php"
mkdir -p "$UPGRADE_DIR/to-apache-bin"

echo "Descompactando PHP..."
unzip -q -o "$PHP_ZIP" -d "$UPGRADE_DIR/php"

echo "Configurando php.ini para o ecossistema XAMPP..."
if [ -f "$UPGRADE_DIR/php/php.ini-development" ]; then
    cp "$UPGRADE_DIR/php/php.ini-development" "$UPGRADE_DIR/php/php.ini"
elif [ -f "$UPGRADE_DIR/php/php.ini-production" ]; then
    cp "$UPGRADE_DIR/php/php.ini-production" "$UPGRADE_DIR/php/php.ini"
fi

if [ -f "$UPGRADE_DIR/php/php.ini" ]; then
    INI="$UPGRADE_DIR/php/php.ini"
    sed -i 's/;extension_dir = "ext"/extension_dir = "\\xampp\\php\\ext"/' "$INI"
    sed -i 's/; extension_dir = "ext"/extension_dir = "\\xampp\\php\\ext"/' "$INI"
    sed -i 's/;upload_tmp_dir =/upload_tmp_dir = "\\xampp\\tmp"/' "$INI"
    sed -i 's/;session.save_path = "\/tmp"/session.save_path = "\\xampp\\tmp"/' "$INI"
    sed -i 's/;curl.cainfo =/curl.cainfo = "\\xampp\\apache\\bin\\curl-ca-bundle.crt"/' "$INI"
    sed -i 's/;openssl.cafile=/openssl.cafile = "\\xampp\\apache\\bin\\curl-ca-bundle.crt"/' "$INI"
    sed -i 's/;extension=bz2/extension=bz2/' "$INI"
    sed -i 's/;extension=curl/extension=curl/' "$INI"
    sed -i 's/;extension=fileinfo/extension=fileinfo/' "$INI"
    sed -i 's/;extension=gd/extension=gd/' "$INI"
    sed -i 's/;extension=gettext/extension=gettext/' "$INI"
    sed -i 's/;extension=mbstring/extension=mbstring/' "$INI"
    sed -i 's/;extension=exif/extension=exif/' "$INI"
    sed -i 's/;extension=mysqli/extension=mysqli/' "$INI"
    sed -i 's/;extension=openssl/extension=openssl/' "$INI"
    sed -i 's/;extension=pdo_mysql/extension=pdo_mysql/' "$INI"
    sed -i 's/;extension=pdo_sqlite/extension=pdo_sqlite/' "$INI"
fi

echo "Copiando DLLs compartilhadas para to-apache-bin..."
cp "$UPGRADE_DIR/php"/icu*.dll "$UPGRADE_DIR/to-apache-bin/" 2>/dev/null || true
cp "$UPGRADE_DIR/php"/lib*.dll "$UPGRADE_DIR/to-apache-bin/" 2>/dev/null || true
cp "$UPGRADE_DIR/php"/nghttp2.dll "$UPGRADE_DIR/to-apache-bin/" 2>/dev/null || true

# Criar script de atualizacao automatica 1-clique (instalar.bat)
cat << 'EOF' > "$UPGRADE_DIR/instalar.bat"
@echo off
setlocal enabledelayedexpansion
title Atualizador de PHP para XAMPP

:: 1. Checar permissao de Administrador
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERRO] Permissao de Administrador necessaria!
    echo Clique com o botao direito neste arquivo e selecione "Executar como Administrador".
    echo.
    pause
    exit /b 1
)

:: 2. Identificar diretorio do XAMPP
set "XAMPP_DIR=C:\xampp"
if not "%~1"=="" set "XAMPP_DIR=%~1"

if not exist "%XAMPP_DIR%\apache" (
    echo [ERRO] O XAMPP nao foi localizado em "%XAMPP_DIR%".
    echo Se seu XAMPP estiver em outro drive/pasta, execute:
    echo   instalar.bat D:\caminho\xampp
    echo.
    pause
    exit /b 1
)

echo ========================================================
echo        Atualizador de PHP para XAMPP
echo ========================================================
echo Destino: %XAMPP_DIR%
echo.

:: 3. Parar processos do Apache
echo [1/5] Parando servicos/processos do Apache...
taskkill /F /IM httpd.exe >nul 2>&1
timeout /t 2 /nobreak >nul

:: 4. Fazer backup da pasta PHP existente
echo [2/5] Criando backup do PHP atual...
set "DATESTAMP=%date:~6,4%%date:~3,2%%date:~0,2%"
set "TIMESTAMP=%time:~0,2%%time:~3,2%%time:~6,2%"
set "TIMESTAMP=%TIMESTAMP: =0%"
set "BACKUP_DIR=%XAMPP_DIR%\php_backup_%DATESTAMP%_%TIMESTAMP%"

if exist "%XAMPP_DIR%\php" (
    echo       Movendo %XAMPP_DIR%\php para %BACKUP_DIR%...
    ren "%XAMPP_DIR%\php" "php_backup_%DATESTAMP%_%TIMESTAMP%"
)

:: 5. Copiar nova pasta PHP
echo [3/5] Instalando nova versao do PHP...
mkdir "%XAMPP_DIR%\php" >nul 2>&1
xcopy /E /I /Y /Q "%~dp0php" "%XAMPP_DIR%\php" >nul

:: 6. Sincronizar DLLs em apache\bin
echo [4/5] Atualizando bibliotecas em %XAMPP_DIR%\apache\bin...
if exist "%~dp0to-apache-bin" (
    xcopy /Y /Q "%~dp0to-apache-bin\*" "%XAMPP_DIR%\apache\bin\" >nul
)

:: Garantir compatibilidade no httpd-xampp.conf se for migracao do PHP 7
if exist "%XAMPP_DIR%\apache\conf\extra\httpd-xampp.conf" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$f = '%XAMPP_DIR%\apache\conf\extra\httpd-xampp.conf'; ^
         $c = Get-Content $f -Raw; ^
         if ($c -match 'php7ts\.dll') { ^
             $c = $c -replace 'php7ts\.dll', 'php8ts.dll'; ^
             $c = $c -replace 'php7apache2_4\.dll', 'php8apache2_4.dll'; ^
             $c = $c -replace 'php7_module', 'php_module'; ^
             Set-Content $f $c; ^
             Write-Host '      [OK] httpd-xampp.conf atualizado para PHP 8.'; ^
         }" >nul 2>&1
)

:: 7. Iniciar o Apache
echo [5/5] Iniciando o Apache...
start "" "%XAMPP_DIR%\apache\bin\httpd.exe"
timeout /t 2 /nobreak >nul

echo.
echo ========================================================
echo           Atualizacao concluida com sucesso!
echo ========================================================
echo Validando versao instalada:
echo.
"%XAMPP_DIR%\php\php.exe" -v
echo.
echo Backup anterior salvo em: %BACKUP_DIR%
echo.
pause
EOF

# Criar script PowerShell equivalente (instalar.ps1) para automacao remota
cat << 'EOF' > "$UPGRADE_DIR/instalar.ps1"
[CmdletBinding()]
param(
    [string]$XamppPath = "C:\xampp"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsPrincipalPolicy]::Administrator)
if (-not $isAdmin) {
    Write-Error "Este script requer privilegios de Administrador."
    exit 1
}

Write-Host "[1/5] Parando processos do Apache..." -ForegroundColor Cyan
Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$backupDir = Join-Path $XamppPath ("php_backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
$phpDir = Join-Path $XamppPath "php"

if (Test-Path $phpDir) {
    Write-Host "[2/5] Criando backup de $phpDir em $backupDir..." -ForegroundColor Cyan
    Rename-Item -Path $phpDir -NewName (Split-Path $backupDir -Leaf)
}

Write-Host "[3/5] Copiando novos binarios do PHP..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $phpDir -Force | Out-Null
Copy-Item -Path (Join-Path $scriptDir "php\*") -Destination $phpDir -Recurse -Force

Write-Host "[4/5] Atualizando DLLs compartilhadas em apache\bin..." -ForegroundColor Cyan
$apacheBin = Join-Path $XamppPath "apache\bin"
if (Test-Path (Join-Path $scriptDir "to-apache-bin")) {
    Copy-Item -Path (Join-Path $scriptDir "to-apache-bin\*") -Destination $apacheBin -Force
}

$httpdConf = Join-Path $XamppPath "apache\conf\extra\httpd-xampp.conf"
if (Test-Path $httpdConf) {
    $c = Get-Content $httpdConf -Raw
    if ($c -match 'php7ts\.dll') {
        $c = $c -replace 'php7ts\.dll', 'php8ts.dll'
        $c = $c -replace 'php7apache2_4\.dll', 'php8apache2_4.dll'
        $c = $c -replace 'php7_module', 'php_module'
        Set-Content -Path $httpdConf -Value $c
    }
}

Write-Host "[5/5] Reiniciando o Apache..." -ForegroundColor Cyan
Start-Process -FilePath (Join-Path $apacheBin "httpd.exe")
Start-Sleep -Seconds 2

Write-Host "`nValidacao da nova versao:" -ForegroundColor Green
& (Join-Path $phpDir "php.exe") -v
EOF

# Compactar pacote final
PACK_NAME="xampp-php${VERSION}-upgrade-pack.zip"
OUTPUT_DIR="/bitnami/dist-${VERSION}-${OS}"
mkdir -p "$OUTPUT_DIR"

echo "Compactando $PACK_NAME..."
cd /tmp
zip -q -r "$PACK_NAME" "xampp-php${VERSION}-upgrade-pack"
mv "$PACK_NAME" "$OUTPUT_DIR/"

echo "Pacote gerado com sucesso em: $OUTPUT_DIR/$PACK_NAME"
