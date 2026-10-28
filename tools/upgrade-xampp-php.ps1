<#
.SYNOPSIS
    Atualiza a versao do PHP em uma instalacao existente do XAMPP sem reinstalacao.

.DESCRIPTION
    Este script automatiza o processo de atualizacao do PHP no XAMPP:
    - Verifica se esta rodando com privilegios de Administrador.
    - Para os processos do Apache (httpd.exe).
    - Cria um backup completo e datado da pasta php atual.
    - Baixa a versao solicitada (ou usa um zip local) oficial Thread Safe x64.
    - Configura o php.ini com as extensoes e caminhos padrao do XAMPP.
    - Sincroniza DLLs compartilhadas em apache\bin (icu*.dll, lib*.dll).
    - Atualiza httpd-xampp.conf caso necessario (migracao do PHP 7 para PHP 8).
    - Reinicia o Apache e valida a versao instalada.

.EXAMPLE
    .\upgrade-xampp-php.ps1 -PhpVersion "8.3.36"
    .\upgrade-xampp-php.ps1 -PhpVersion "8.2.35" -XamppPath "D:\xampp"
    .\upgrade-xampp-php.ps1 -LocalZip "C:\downloads\php-8.3.36-Win32-vs16-x64.zip"
#>

[CmdletBinding()]
param (
    [string]$XamppPath = "C:\xampp",
    [string]$PhpVersion = "8.3.36",
    [string]$LocalZip = ""
)

$ErrorActionPreference = "Stop"

function Write-Step ($msg) {
    Write-Host "`n[+] $msg" -ForegroundColor Cyan
}

# 1. Validar privilegios de Administrador
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsPrincipalPolicy]::Administrator)
if (-not $isAdmin) {
    Write-Error "Este script precisa ser executado como Administrador para gerenciar servicos e pastas do XAMPP."
    exit 1
}

# 2. Validar caminhos do XAMPP
$apacheDir = Join-Path $XamppPath "apache"
$phpDir    = Join-Path $XamppPath "php"

if (-not (Test-Path $apacheDir)) {
    Write-Error "O diretorio do Apache nao foi encontrado em '$apacheDir'. Verifique o parametro -XamppPath."
    exit 1
}

# 3. Determinar versao do compilador (VS16 para 8.2/8.3, VS17 para 8.4/8.5)
$cleanVer = ($PhpVersion -split '-')[0]
$vcVersion = if ([version]$cleanVer -ge [version]"8.4.0") { "vs17" } else { "vs16" }
$zipName = "php-$PhpVersion-Win32-$vcVersion-x64.zip"
$tempZip = if ($LocalZip) { $LocalZip } else { Join-Path $env:TEMP $zipName }

# 4. Baixar o arquivo (se nao fornecido localmente)
if (-not $LocalZip) {
    Write-Step "Baixando PHP $PhpVersion (Thread-Safe x64)..."
    $downloadUrl = "https://windows.php.net/downloads/releases/$zipName"
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
    } catch {
        Write-Host "Arquivo nao encontrado na pasta principal, tentando arquivo historico..." -ForegroundColor Yellow
        $downloadUrl = "https://windows.php.net/downloads/releases/archives/$zipName"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
    }
}

if (-not (Test-Path $tempZip)) {
    Write-Error "Arquivo ZIP nao encontrado em: $tempZip"
    exit 1
}

# 5. Parar o Apache
Write-Step "Parando processos do Apache (httpd.exe)..."
Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# 6. Criar Backup do PHP Atual
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $XamppPath "php_backup_$timestamp"
if (Test-Path $phpDir) {
    Write-Step "Criando backup do PHP atual em: $backupDir"
    Rename-Item -Path $phpDir -NewName (Split-Path $backupDir -Leaf)
}

# 7. Extrair Nova Versao
Write-Step "Extraindo nova versao em '$phpDir'..."
New-Item -ItemType Directory -Path $phpDir -Force | Out-Null
Expand-Archive -Path $tempZip -DestinationPath $phpDir -Force

# 8. Configurar php.ini
Write-Step "Configurando php.ini..."
$oldIni = Join-Path $backupDir "php.ini"
$newIni = Join-Path $phpDir "php.ini"

if (Test-Path $oldIni) {
    Write-Host "Migrando configuracoes do php.ini existente..." -ForegroundColor Green
    Copy-Item $oldIni $newIni
} else {
    Write-Host "Criando php.ini a partir de php.ini-development..." -ForegroundColor Green
    Copy-Item (Join-Path $phpDir "php.ini-development") $newIni
    
    $iniContent = Get-Content $newIni
    $iniContent = $iniContent -replace ';extension_dir = "ext"', "extension_dir = `"$phpDir\ext`""
    $iniContent = $iniContent -replace ';extension=curl', 'extension=curl'
    $iniContent = $iniContent -replace ';extension=fileinfo', 'extension=fileinfo'
    $iniContent = $iniContent -replace ';extension=gd', 'extension=gd'
    $iniContent = $iniContent -replace ';extension=mbstring', 'extension=mbstring'
    $iniContent = $iniContent -replace ';extension=mysqli', 'extension=mysqli'
    $iniContent = $iniContent -replace ';extension=openssl', 'extension=openssl'
    $iniContent = $iniContent -replace ';extension=pdo_mysql', 'extension=pdo_mysql'
    $iniContent = $iniContent -replace ';upload_tmp_dir =', "upload_tmp_dir = `"$XamppPath\tmp`""
    $iniContent = $iniContent -replace ';session\.save_path = "\/tmp"', "session.save_path = `"$XamppPath\tmp`""
    Set-Content -Path $newIni -Value $iniContent
}

# 9. Copiar DLLs compartilhadas para apache\bin
Write-Step "Sincronizando DLLs em apache\bin..."
$apacheBin = Join-Path $apacheDir "bin"
Get-ChildItem -Path $phpDir -Filter "icu*.dll" | Copy-Item -Destination $apacheBin -Force
Get-ChildItem -Path $phpDir -Filter "lib*.dll" | Copy-Item -Destination $apacheBin -Force -ErrorAction SilentlyContinue

# 10. Atualizar httpd-xampp.conf se necessario
$httpdConf = Join-Path $apacheDir "conf\extra\httpd-xampp.conf"
if (Test-Path $httpdConf) {
    $c = Get-Content $httpdConf -Raw
    if ($c -match 'php7ts\.dll') {
        Write-Step "Atualizando diretivas do Apache de PHP 7 para PHP 8..."
        $c = $c -replace 'php7ts\.dll', 'php8ts.dll'
        $c = $c -replace 'php7apache2_4\.dll', 'php8apache2_4.dll'
        $c = $c -replace 'php7_module', 'php_module'
        Set-Content -Path $httpdConf -Value $c
    }
}

# 11. Iniciar o Apache
Write-Step "Iniciando o Apache..."
$httpdExe = Join-Path $apacheBin "httpd.exe"
Start-Process -FilePath $httpdExe
Start-Sleep -Seconds 2

# 12. Validar
Write-Step "Resultado da atualizacao:"
$phpExe = Join-Path $phpDir "php.exe"
if (Test-Path $phpExe) {
    & $phpExe -v
    Write-Host "`n[SUCESSO] PHP atualizado com exito!" -ForegroundColor Green
    Write-Host "Backup da versao anterior: $backupDir" -ForegroundColor DarkGray
} else {
    Write-Error "Nao foi possivel encontrar o executavel $phpExe."
}
