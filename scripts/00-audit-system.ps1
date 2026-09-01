<#
.SYNOPSIS
    Аудит системы перед установкой Home Assistant. Ничего не меняет.
.DESCRIPTION
    Собирает информацию о железе, дисках, сети и готовности к виртуализации.
    Результат сохраняется в audit-report.txt рядом со скриптом.
.NOTES
    Запускать от имени администратора.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Continue'
$report = [System.Collections.Generic.List[string]]::new()

function Write-Section {
    param([string]$Title)
    $line = "`n=== $Title ==="
    Write-Host $line -ForegroundColor Cyan
    $report.Add($line)
}

function Write-Item {
    param([string]$Label, [string]$Value, [string]$Status = 'INFO')
    $color = switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    $line = "  {0,-32} {1}" -f "$Label :", $Value
    Write-Host $line -ForegroundColor $color
    $report.Add("[$Status] $line")
}

Write-Host "`n  АУДИТ СИСТЕМЫ ДЛЯ HOME ASSISTANT" -ForegroundColor White
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor DarkGray

# ---------------------------------------------------------------- Система
Write-Section "Система"
$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS

Write-Item "Имя компьютера"  $env:COMPUTERNAME
Write-Item "ОС"              "$($os.Caption) $($os.Version)"
Write-Item "Сборка"          $os.BuildNumber
Write-Item "Производитель"   $cs.Manufacturer
Write-Item "Модель"          $cs.Model
Write-Item "BIOS версия"     $bios.SMBIOSBIOSVersion

# Проверка редакции — Hyper-V есть только в Pro/Enterprise/Education
$edition = (Get-CimInstance Win32_OperatingSystem).Caption
if ($edition -match 'Pro|Enterprise|Education') {
    Write-Item "Редакция для Hyper-V" "$edition" 'OK'
} else {
    Write-Item "Редакция для Hyper-V" "$edition — Hyper-V НЕДОСТУПЕН" 'FAIL'
}

# ---------------------------------------------------------------- CPU
Write-Section "Процессор"
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Write-Item "Модель"          $cpu.Name.Trim()
Write-Item "Ядра / Потоки"   "$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)"

if ($cpu.VirtualizationFirmwareEnabled -eq $true) {
    Write-Item "VT-x в BIOS"  "Включена" 'OK'
} elseif ($cpu.VirtualizationFirmwareEnabled -eq $false) {
    Write-Item "VT-x в BIOS"  "ВЫКЛЮЧЕНА — включить в BIOS (F2 при старте)" 'FAIL'
} else {
    Write-Item "VT-x в BIOS"  "Не определено (возможно Hyper-V уже активен)" 'WARN'
}

# ---------------------------------------------------------------- Память
Write-Section "Оперативная память"
$totalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
Write-Item "Всего"           "$totalGB ГБ"
Write-Item "Свободно"        "$freeGB ГБ"

if ($totalGB -ge 8) {
    Write-Item "Достаточно для VM" "Да (нужно 4 ГБ для HAOS)" 'OK'
} else {
    Write-Item "Достаточно для VM" "Мало — рекомендуется 8+ ГБ" 'WARN'
}

Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    $slotGB = [math]::Round($_.Capacity / 1GB, 0)
    Write-Item "  Слот $($_.DeviceLocator)" "$slotGB ГБ @ $($_.Speed) МГц"
}

# ---------------------------------------------------------------- Диски
Write-Section "Накопители"
Get-PhysicalDisk | ForEach-Object {
    $sizeGB = [math]::Round($_.Size / 1GB, 0)
    Write-Item "Диск $($_.DeviceId)" "$($_.FriendlyName) — $sizeGB ГБ ($($_.MediaType), $($_.BusType))"
}

Write-Host ""
Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
    $freeGB  = [math]::Round($_.SizeRemaining / 1GB, 1)
    $totalGB = [math]::Round($_.Size / 1GB, 1)
    $pct     = if ($_.Size -gt 0) { [math]::Round(($_.SizeRemaining / $_.Size) * 100, 0) } else { 0 }
    $status  = if ($freeGB -ge 80) { 'OK' } elseif ($freeGB -ge 40) { 'WARN' } else { 'FAIL' }
    Write-Item "Том $($_.DriveLetter):" "$freeGB / $totalGB ГБ свободно ($pct%)" $status
}

$sysFree = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 1)
if ($sysFree -lt 80) {
    Write-Item "ВНИМАНИЕ" "Для VHDX нужно ~70 ГБ. Свободно $sysFree ГБ" 'WARN'
}

# ---------------------------------------------------------------- Сеть
Write-Section "Сетевые адаптеры"
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
    $ip = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    Write-Item $_.Name "$($_.InterfaceDescription)"
    Write-Item "  MAC"    $_.MacAddress
    Write-Item "  IP"     ($ip -join ', ')
    Write-Item "  Скорость" $_.LinkSpeed
}

# Проверка: подключён ли по кабелю
$ethUp = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }
if ($ethUp) {
    Write-Item "Проводное подключение" "Есть — $($ethUp[0].Name)" 'OK'
} else {
    Write-Item "Проводное подключение" "НЕТ — для стабильности подключите кабель" 'WARN'
}

# ---------------------------------------------------------------- Hyper-V
Write-Section "Готовность Hyper-V"
$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
if ($hv) {
    $status = if ($hv.State -eq 'Enabled') { 'OK' } else { 'WARN' }
    Write-Item "Компонент Hyper-V" $hv.State $status
} else {
    Write-Item "Компонент Hyper-V" "Не найден" 'FAIL'
}

$vms = Get-VM -ErrorAction SilentlyContinue
if ($vms) {
    Write-Item "Существующие VM" (($vms | ForEach-Object { "$($_.Name) [$($_.State)]" }) -join ', ')
} else {
    Write-Item "Существующие VM" "Нет"
}

# ---------------------------------------------------------------- Питание
Write-Section "Настройки питания"
$scheme = (powercfg /getactivescheme) -replace '.*\(([^)]+)\).*', '$1'
Write-Item "Активная схема" $scheme

$hiberFile = Test-Path "$env:SystemDrive\hiberfil.sys"
Write-Item "Гибернация" $(if ($hiberFile) { "Включена — будет отключена" } else { "Отключена" }) $(if ($hiberFile) { 'WARN' } else { 'OK' })

# ---------------------------------------------------------------- Сеть: доступность Zigbee-донгла
Write-Section "Проверка SONOFF Dongle Max"
$dongleIp = '192.168.1.11'
$ping = Test-Connection -ComputerName $dongleIp -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($ping) {
    Write-Item "Ping $dongleIp" "Отвечает" 'OK'
    $tcp = Test-NetConnection -ComputerName $dongleIp -Port 6638 -WarningAction SilentlyContinue
    Write-Item "Порт 6638 (ser2net)" $(if ($tcp.TcpTestSucceeded) { "Открыт" } else { "Закрыт" }) $(if ($tcp.TcpTestSucceeded) { 'OK' } else { 'WARN' })
} else {
    Write-Item "Ping $dongleIp" "Не отвечает — донгл ещё не подключён или другой IP" 'WARN'
}

# ---------------------------------------------------------------- Итог
Write-Section "Итог"
$blockers = $report | Where-Object { $_ -match '^\[FAIL\]' }
if ($blockers) {
    Write-Host "`n  БЛОКЕРЫ (исправить до установки):" -ForegroundColor Red
    $blockers | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
} else {
    Write-Host "`n  Блокеров нет — можно запускать 01-prepare-windows.ps1" -ForegroundColor Green
}

$reportPath = Join-Path $PSScriptRoot 'audit-report.txt'
$report | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "`n  Отчёт сохранён: $reportPath`n" -ForegroundColor DarkGray
