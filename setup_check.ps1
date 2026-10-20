<#
.SYNOPSIS
  Проверка окружения для проекта «Складской учёт».

.DESCRIPTION
  Проверяет по порядку:
    1. RAD Studio 13.1 (dcc64.exe) — нужен для сборки
    2. sqlcmd — утилита проверки БД (ищется в PATH и стандартных путях)
    3. ODBC Driver 18 for SQL Server — на нём работает приложение
    4. Доступность SQL Server Express (Windows-аутентификация)
    5. Протокол TCP/IP
    6. Наличие базы WarehouseDB и схемы проекта

  Только чтение: ничего не устанавливает и не меняет.
  Запуск:  powershell -ExecutionPolicy Bypass -File setup_check.ps1

  Параметры не обязательны: значения по умолчанию совпадают со строкой
  подключения в uDM.pas (localhost\SQLEXPRESS, WarehouseDB).
#>

param(
    [string]$SqlInstance = 'localhost\SQLEXPRESS',
    [string]$DbName      = 'WarehouseDB',
    [string]$StudioPath  = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
)

$script:failed = 0

function Write-Ok   { param([string]$Msg) Write-Host "  [OK]   $Msg" -ForegroundColor Green }
function Write-Bad  { param([string]$Msg, [string]$Hint = '')
    $script:failed++
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
    if ($Hint) { Write-Host "         -> $Hint" -ForegroundColor Yellow }
}
function Write-Info { param([string]$Msg) Write-Host "  [INFO] $Msg" -ForegroundColor DarkGray }

# sqlcmd лежит не только в PATH: у ODBC SDK свои каталоги.
function Find-Sqlcmd {
    $cmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @(
        "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC",
        "${env:ProgramFiles}\Microsoft SQL Server"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter SQLCMD.EXE -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

# sqlcmd возвращает текст; бросаем исключение, если сам процесс не запустился.
function Invoke-Check([string]$sqlcmd, [string]$query, [string]$db) {
    $args = @('-S', $SqlInstance, '-E', '-C', '-h', '-1', '-W', '-Q', $query)
    if ($db)     { $args += @('-d', $db) }
    $out = & $sqlcmd @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($out | Out-String).Trim()
    }
    return (($out | Out-String).Trim())
}

Write-Host ''
Write-Host '=== Складской учёт: проверка окружения ===' -ForegroundColor Cyan
Write-Host ''

# ── 1. RAD Studio ──────────────────────────────────────────────────
$dcc = Join-Path $StudioPath 'bin64\dcc64.exe'
if (Test-Path $dcc) {
    Write-Ok "RAD Studio: $dcc"
} else {
    Write-Bad 'RAD Studio 13.1 не найден' "ожидается $dcc; установите RAD Studio или поправьте -StudioPath"
}

# ── 2. sqlcmd ──────────────────────────────────────────────────────
$sqlcmd = Find-Sqlcmd
if ($sqlcmd) {
    Write-Ok "sqlcmd: $sqlcmd"
} else {
    Write-Bad 'sqlcmd не найден' 'установите ODBC Driver 18 (в комплекте SQLCMD) или SQL Server Feature Pack'
}

# ── 3. ODBC Driver 18 (на нём подключается FireDAC) ────────────────
$odbcKeys = @(
    'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server',
    'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server'
)
if ($odbcKeys | Where-Object { Test-Path $_ }) {
    Write-Ok 'ODBC Driver 18 for SQL Server установлен'
} else {
    Write-Bad 'ODBC Driver 18 не найден' 'скачайте: https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server'
}

# ── 4. Доступность SQL Server ──────────────────────────────────────
$sqlOk = $false
if ($sqlcmd) {
    try {
        $ver = Invoke-Check $sqlcmd 'SELECT @@VERSION' $null
        Write-Ok "SQL Server доступен ($SqlInstance):"
        ($ver -split "`n" | Select-Object -First 2 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray })
        $sqlOk = $true
    } catch {
        Write-Bad "SQL Server недоступен ($SqlInstance)" "проверьте службу 'SQL Server (SQLEXPRESS)' в services.msc; ошибка: $($_.Exception.Message)"
    }
}

# ── 5. Протокол TCP/IP ─────────────────────────────────────────────
# Для локального экземпляра Shared memory — норма и даже быстрее TCP:
# приложение (FireDAC) ходит тем же каналом. TCP/IP обязателен только
# при доступе к серверу с другой машины (например, SQL в Docker).
if ($sqlOk) {
    try {
        $transport = (Invoke-Check $sqlcmd 'SET NOCOUNT ON; SELECT net_transport FROM sys.dm_exec_connections WHERE session_id = @@SPID' $null) -replace '\s+', ' '
        $isLocal = $SqlInstance -match '(?i)^(localhost|\.|\(local\)|\(localdb\))'
        if ($transport -match 'TCP') {
            Write-Ok 'Соединение идёт по TCP/IP'
        } elseif ($isLocal) {
            Write-Info "Локальное соединение через $transport — это нормально. TCP/IP понадобится, если SQL Server будет доступен с другой машины (Docker, сетевой запуск)."
        } else {
            Write-Bad "Удалённое соединение идёт через $transport, а не TCP" `
                'включите: SQL Server Configuration Manager -> Protocols for <экземпляр> -> TCP/IP -> Enabled -> перезапуск службы'
        }
    } catch {
        Write-Bad 'Не удалось определить протокол' $_.Exception.Message
    }
}

# ── 6. База и схема проекта ────────────────────────────────────────
if ($sqlOk) {
    try {
        $dbId = Invoke-Check $sqlcmd "SELECT DB_ID(N'$DbName')" 'master'
        if ($dbId -match '^\s*0\s*$') {
            Write-Bad "База $DbName не создана" "sqlcmd -S `"$SqlInstance`" -E -C -i Sql\01_schema.sql"
        } else {
            Write-Ok "База $DbName существует"
            try {
                $cnt = Invoke-Check $sqlcmd 'SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Goods' $DbName
                Write-Ok "Схема на месте, товаров в справочнике: $($cnt.Trim())"
            } catch {
                Write-Bad 'Таблицы схемы не найдены' "выполните Sql\01_schema.sql и Sql\02_seed.sql"
            }
        }
    } catch {
        Write-Bad 'Не удалось проверить базу' $_.Exception.Message
    }
}

# ── Итог ───────────────────────────────────────────────────────────
Write-Host ''
if ($failed -eq 0) {
    Write-Host 'Окружение готово: можно собирать (build_fmx.ps1) и запускать (bin\Warehouse.exe).' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Проблем: $failed. Исправьте отмеченные [FAIL] и запустите проверку снова." -ForegroundColor Red
    exit 1
}
