<#
.SYNOPSIS
    Подготовка Windows 11 Pro для круглосуточной работы Home Assistant в Hyper-V.
.DESCRIPTION
    Выполняет:
      - отключение всех режимов сна и гибернации
      - план питания High Performance
      - отсрочку и контроль Windows Update (без внезапных перезагрузок)
      - включение RDP как резервного канала доступа
      - включение компонента Hyper-V
    В конце потребуется перезагрузка.
.NOTES
    Запускать от имени администратора.
    Идемпотентен — можно запускать повторно.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # Режим настройки вне дома (например, в офисе) через удалённое подключение.
    # Пропускает всё, что может разорвать текущее сетевое соединение или
    # изменить профиль чужой сети:
    #   - смену профиля сети на Private
    #   - отключение управления питанием сетевых адаптеров
    # Эти шаги нужно выполнить дома скриптом с ключом -HomeNetworkOnly.
    [switch]$AtOffice,

    # Выполнить ТОЛЬКО те сетевые шаги, которые были пропущены с -AtOffice.
    [switch]$HomeNetworkOnly
)

$ErrorActionPreference = 'Stop'
$needReboot = $false

function Step {
    param([string]$Text)
    Write-Host "`n[*] $Text" -ForegroundColor Cyan
}
function Ok {
    param([string]$Text)
    Write-Host "    OK  $Text" -ForegroundColor Green
}
function Warn {
    param([string]$Text)
    Write-Host "    !   $Text" -ForegroundColor Yellow
}

Write-Host "`n  ПОДГОТОВКА WINDOWS ДЛЯ HOME ASSISTANT" -ForegroundColor White
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray

if ($AtOffice) {
    Write-Host "`n  РЕЖИМ: настройка вне дома (-AtOffice)" -ForegroundColor Yellow
    Write-Host "  Сетевые настройки НЕ трогаем, чтобы не оборвать удалённое" -ForegroundColor Yellow
    Write-Host "  подключение. Дома нужно будет запустить:" -ForegroundColor Yellow
    Write-Host "      .\01-prepare-windows.ps1 -HomeNetworkOnly" -ForegroundColor Yellow
}
if ($HomeNetworkOnly) {
    Write-Host "`n  РЕЖИМ: только сетевые шаги (-HomeNetworkOnly)" -ForegroundColor Cyan
}

if ($HomeNetworkOnly) {
    # --- Только то, что было пропущено в офисе ---
    Step "Профиль сети -> Private"
    try {
        Get-NetConnectionProfile | ForEach-Object {
            if ($_.NetworkCategory -ne 'Private') {
                Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
                Ok "Сеть '$($_.Name)' переведена в Private"
            } else { Ok "Сеть '$($_.Name)' уже Private" }
        }
    } catch { Warn "Не удалось: $($_.Exception.Message)" }

    Enable-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction SilentlyContinue
    Ok "Сетевое обнаружение включено"

    Step "Запрет сна для сетевых адаптеров"
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        try {
            Disable-NetAdapterPowerManagement -Name $_.Name -ErrorAction Stop
            Ok "Адаптер '$($_.Name)': управление питанием отключено"
        } catch {
            Warn "Адаптер '$($_.Name)': не поддерживает настройку"
        }
    }

    Write-Host "`n  Сетевые шаги выполнены. Дальше: .\02-install-haos-vm.ps1`n" -ForegroundColor Green
    exit 0
}

# ================================================================ 1. Питание
Step "Настройка электропитания (режим 24/7)"

# Схема High Performance (GUID постоянный во всех версиях Windows)
$highPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
powercfg /setactive $highPerf 2>$null
if ($LASTEXITCODE -eq 0) {
    Ok "План питания: High Performance"
} else {
    # На некоторых системах схема скрыта — дублируем её
    powercfg /duplicatescheme $highPerf 2>$null | Out-Null
    powercfg /setactive $highPerf 2>$null
    Ok "План питания: High Performance (восстановлен)"
}

# Отключить гибернацию (освобождает hiberfil.sys = размер RAM)
powercfg /hibernate off
Ok "Гибернация отключена (освобождено ~16 ГБ)"

# Все таймауты сна и отключения = 0 (никогда)
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0
powercfg /change disk-timeout-ac 0
powercfg /change disk-timeout-dc 0
powercfg /change monitor-timeout-ac 15   # монитор гасим — на потребление не влияет
powercfg /change monitor-timeout-dc 15
Ok "Сон, гибернация, отключение дисков — выключены"

# USB selective suspend off (важно если позже подключите USB-донгл)
powercfg /setacvalueindex $highPerf 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setdcvalueindex $highPerf 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
Ok "USB selective suspend отключён"

# Кнопка питания ничего не делает (защита от случайного нажатия)
powercfg /setacvalueindex $highPerf 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 0
Ok "Кнопка питания: не выключает систему"

powercfg /setactive $highPerf

# Запретить сетевым адаптерам засыпать
Step "Запрет сна для сетевых адаптеров"
if ($AtOffice) {
    Warn "ПРОПУЩЕНО (-AtOffice): изменение адаптера может оборвать удалённый сеанс"
    Warn "Выполнить дома: .\01-prepare-windows.ps1 -HomeNetworkOnly"
}
if (-not $AtOffice) {
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
    try {
        Disable-NetAdapterPowerManagement -Name $_.Name -ErrorAction Stop
        Ok "Адаптер '$($_.Name)': управление питанием отключено"
    } catch {
        Warn "Адаптер '$($_.Name)': не поддерживает настройку ($($_.Exception.Message.Split([Environment]::NewLine)[0]))"
    }
}
}

# ================================================================ 2. Windows Update
Step "Настройка Windows Update (без внезапных перезагрузок)"

$wuPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$auPolicy = "$wuPolicy\AU"
New-Item -Path $wuPolicy -Force | Out-Null
New-Item -Path $auPolicy  -Force | Out-Null

# Отсрочка обновлений
Set-ItemProperty -Path $wuPolicy -Name 'DeferFeatureUpdates'              -Value 1   -Type DWord
Set-ItemProperty -Path $wuPolicy -Name 'DeferFeatureUpdatesPeriodInDays'  -Value 365 -Type DWord
Set-ItemProperty -Path $wuPolicy -Name 'DeferQualityUpdates'              -Value 1   -Type DWord
Set-ItemProperty -Path $wuPolicy -Name 'DeferQualityUpdatesPeriodInDays'  -Value 30  -Type DWord
Ok "Функциональные обновления отложены на 365 дней"
Ok "Обновления безопасности отложены на 30 дней"

# Не перезагружать при активной сессии
Set-ItemProperty -Path $auPolicy -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord
Set-ItemProperty -Path $auPolicy -Name 'AUOptions'                     -Value 3 -Type DWord  # скачивать, но спрашивать об установке
Ok "Автоперезагрузка при активном пользователе запрещена"

# Расширенные Active Hours (максимум 18 часов)
$uxSettings = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
if (Test-Path $uxSettings) {
    Set-ItemProperty -Path $uxSettings -Name 'ActiveHoursStart' -Value 6  -Type DWord
    Set-ItemProperty -Path $uxSettings -Name 'ActiveHoursEnd'   -Value 0  -Type DWord   # до полуночи
    Set-ItemProperty -Path $uxSettings -Name 'SmartActiveHoursState' -Value 0 -Type DWord
    Ok "Активные часы: 06:00 – 00:00 (обновления только ночью)"
}

# ================================================================ 3. RDP
Step "Включение RDP (резервный канал доступа)"

Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
                 -Name 'fDenyTSConnections' -Value 0 -Type DWord
Ok "RDP включён"

# NLA — требовать аутентификацию на уровне сети (безопаснее)
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
                 -Name 'UserAuthentication' -Value 1 -Type DWord
Ok "Network Level Authentication включена"

# Правило firewall — ТОЛЬКО для локальной сети, не наружу
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue |
    Set-NetFirewallRule -RemoteAddress LocalSubnet
Ok "Firewall: RDP разрешён только из локальной сети"

# ================================================================ 4. Имя и обнаружение в сети
Step "Настройка сетевого обнаружения"
if ($AtOffice) {
    Warn "ПРОПУЩЕНО (-AtOffice): не меняем профиль рабочей сети"
    Warn "Рабочая сеть должна оставаться Public — это требование безопасности"
} else {
try {
    # Профиль текущей сети → Private (иначе RDP и обнаружение блокируются)
    Get-NetConnectionProfile | ForEach-Object {
        if ($_.NetworkCategory -ne 'Private') {
            Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
            Ok "Сеть '$($_.Name)' переведена в профиль Private"
        } else {
            Ok "Сеть '$($_.Name)' уже Private"
        }
    }
} catch {
    Warn "Не удалось сменить профиль сети: $($_.Exception.Message)"
}

Enable-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction SilentlyContinue
Ok "Сетевое обнаружение включено"
}

# ================================================================ 5. Hyper-V
Step "Включение Hyper-V"

$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hv.State -eq 'Enabled') {
    Ok "Hyper-V уже включён"
} else {
    Write-Host "    Установка компонента (может занять 2–5 минут)..." -ForegroundColor DarkGray
    $result = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
    Ok "Hyper-V установлен"
    if ($result.RestartNeeded) { $needReboot = $true }
}

# ================================================================ 6. Проверка виртуализации
Step "Проверка поддержки виртуализации"
$sysInfo = systeminfo.exe 2>$null | Select-String -Pattern 'Hyper-V|Гипервизор|Virtualization|Виртуализация'
if ($sysInfo) {
    $sysInfo | ForEach-Object { Write-Host "    $($_.Line.Trim())" -ForegroundColor DarkGray }
}

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($cpu.VirtualizationFirmwareEnabled -eq $false) {
    Warn "VT-x ВЫКЛЮЧЕНА в BIOS! Перезагрузитесь, нажмите F2 и включите Intel Virtualization Technology"
}

# ================================================================ 7. Планировщик: убрать пробуждающие задачи
Step "Отключение задач, будящих систему"
try {
    Get-ScheduledTask | Where-Object { $_.Settings.WakeToRun -eq $true -and $_.State -ne 'Disabled' } |
        ForEach-Object {
            $t = $_
            $t.Settings.WakeToRun = $false
            Set-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue | Out-Null
            Ok "Задача '$($t.TaskName)': пробуждение отключено"
        }
} catch {
    Warn "Часть задач изменить не удалось (системные — это нормально)"
}

# ================================================================ Итог
Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
Write-Host "  ПОДГОТОВКА ЗАВЕРШЕНА" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor DarkGray

Write-Host @"

  Дальнейшие шаги:

  1. ПЕРЕЗАГРУЗИТЬ компьютер (обязательно — активирует Hyper-V)
  2. Установить МойАссистент вручную:
       - Скачать: мойассистент.рф -> Скачать -> Windows
       - Установить, настроить постоянный пароль (неконтролируемый доступ)
       - Включить автозапуск при старте Windows
       - Записать ID устройства
  3. Запустить: .\02-install-haos-vm.ps1

  Резервный доступ уже работает:
       RDP на $((Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
              Select-Object -First 1 -ExpandProperty IPAddress)):3389
       Пользователь: $env:USERNAME

"@ -ForegroundColor White

if ($needReboot) {
    Write-Host ("=" * 60) -ForegroundColor Red
    Write-Host "  ВНИМАНИЕ: ПЕРЕД ПЕРЕЗАГРУЗКОЙ" -ForegroundColor Red
    Write-Host ("=" * 60) -ForegroundColor Red
    Write-Host @"

  Если вы работаете через удалённый доступ — после перезагрузки
  соединение оборвётся. Оно восстановится ТОЛЬКО если программа
  удалённого доступа запускается автоматически вместе с Windows.

  Проверьте ДО перезагрузки:
    [ ] В МойАссистент включён автозапуск при старте Windows
    [ ] Задан постоянный пароль (неконтролируемый доступ),
        а не одноразовый код
    [ ] ID устройства записан отдельно

  Резервный канал, если МойАссистент не поднимется:
    RDP -> $((Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object { `$_.IPAddress -notlike '127.*' -and `$_.IPAddress -notlike '169.254.*' } |
              Select-Object -First 1 -ExpandProperty IPAddress)):3389
    Пользователь: $env:USERNAME

  Если ни то, ни другое не настроено — понадобится монитор и клавиатура.

"@ -ForegroundColor Yellow

    Write-Host "  Требуется перезагрузка. Выполнить сейчас? (y/n): " -ForegroundColor Yellow -NoNewline
    $answer = Read-Host
    if ($answer -match '^[yYдД]') {
        Write-Host "  Перезагрузка через 10 секунд..." -ForegroundColor Yellow
        Restart-Computer -Force -Delay 10
    } else {
        Write-Host "  Перезагрузите вручную перед запуском следующего скрипта.`n" -ForegroundColor Yellow
    }
}
