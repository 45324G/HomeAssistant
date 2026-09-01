<#
.SYNOPSIS
    Полностью автоматическая установка Home Assistant OS как VM в Hyper-V.
.DESCRIPTION
    Выполняет без участия пользователя:
      1. Определяет последнюю версию HAOS через GitHub API
      2. Скачивает VHDX-образ и распаковывает
      3. Создаёт External Virtual Switch на физическом адаптере
      4. Создаёт VM Gen2 с отключённым Secure Boot
      5. Настраивает статическую память, автостарт, отключает авточекпоинты
      6. Запускает VM и ждёт появления HA в сети
.PARAMETER VMName
    Имя виртуальной машины. По умолчанию "HomeAssistant".
.PARAMETER MemoryGB
    Объём памяти в ГБ (статический). По умолчанию 4.
.PARAMETER CPUCount
    Количество виртуальных процессоров. По умолчанию 2.
.PARAMETER VMPath
    Каталог для файлов VM. По умолчанию C:\HyperV.
.NOTES
    Запускать от имени администратора ПОСЛЕ перезагрузки после 01-prepare-windows.ps1.
    Идемпотентен: при повторном запуске существующая VM не пересоздаётся.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$VMName   = 'HomeAssistant',
    [int]   $MemoryGB = 4,
    [int]   $CPUCount = 2,
    [string]$VMPath   = 'C:\HyperV',
    [string]$SwitchName = 'HA-External',

    # Только скачать и распаковать образ HAOS, не создавая VM.
    # Удобно выполнить заранее на быстром интернете (например, в офисе),
    # а саму VM создать позже дома, когда NUC будет в целевой сети.
    [switch]$DownloadOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # ускоряет Invoke-WebRequest в разы

function Step { param([string]$t) Write-Host "`n[*] $t" -ForegroundColor Cyan }
function Ok   { param([string]$t) Write-Host "    OK  $t" -ForegroundColor Green }
function Warn { param([string]$t) Write-Host "    !   $t" -ForegroundColor Yellow }
function Die  { param([string]$t) Write-Host "    X   $t" -ForegroundColor Red; exit 1 }

Write-Host "`n  УСТАНОВКА HOME ASSISTANT OS В HYPER-V" -ForegroundColor White
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray

# ================================================================ 0. Предусловия
Step "Проверка предусловий"

$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hv.State -ne 'Enabled') {
    if ($DownloadOnly) {
        Warn "Hyper-V ещё не включён — для скачивания образа это не важно"
    } else {
        Die "Hyper-V не включён. Запустите 01-prepare-windows.ps1 и перезагрузитесь."
    }
} else {
    Ok "Hyper-V активен"
}

if (-not $DownloadOnly) {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        Die "Модуль Hyper-V PowerShell недоступен. Перезагрузитесь после включения Hyper-V."
    }
    Ok "Модуль Hyper-V PowerShell загружен"
}

# Свободное место: образ ~1.5 ГБ + распакованный ~6 ГБ + рост VHDX
$targetDrive = (Split-Path -Qualifier $VMPath).TrimEnd(':')
$freeGB = [math]::Round((Get-Volume -DriveLetter $targetDrive).SizeRemaining / 1GB, 1)
if ($freeGB -lt 40) {
    Die "На диске ${targetDrive}: только $freeGB ГБ. Нужно минимум 40 ГБ."
}
Ok "Свободно на ${targetDrive}: $freeGB ГБ"

New-Item -ItemType Directory -Path $VMPath -Force | Out-Null
$downloadDir = Join-Path $VMPath 'download'
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

# ================================================================ 1. Уже существует?
Step "Проверка существующей VM"
$existingVM = if ($DownloadOnly) { $null } else { Get-VM -Name $VMName -ErrorAction SilentlyContinue }
if ($existingVM) {
    Warn "VM '$VMName' уже существует (состояние: $($existingVM.State))"
    Write-Host "    Пересоздать? Все данные HA будут ПОТЕРЯНЫ. (введите 'DELETE' для подтверждения): " -ForegroundColor Yellow -NoNewline
    $confirm = Read-Host
    if ($confirm -ne 'DELETE') {
        Write-Host "`n  Отменено. Существующая VM не тронута." -ForegroundColor Green
        if ($existingVM.State -ne 'Running') {
            Write-Host "  VM остановлена. Запустить? (y/n): " -ForegroundColor Yellow -NoNewline
            if ((Read-Host) -match '^[yYдД]') { Start-VM -Name $VMName; Ok "VM запущена" }
        }
        exit 0
    }
    if ($existingVM.State -ne 'Off') { Stop-VM -Name $VMName -Force -TurnOff }
    $oldDisks = (Get-VMHardDiskDrive -VMName $VMName).Path
    Remove-VM -Name $VMName -Force
    $oldDisks | Where-Object { Test-Path $_ } | Remove-Item -Force
    Ok "Старая VM удалена"
} else {
    Ok "VM с именем '$VMName' не найдена — создаём новую"
}

# ================================================================ 2. Определение версии HAOS
Step "Определение последней версии Home Assistant OS"

$apiUrl = 'https://api.github.com/repos/home-assistant/operating-system/releases/latest'
try {
    $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'HA-Setup-Script' } -TimeoutSec 30
} catch {
    Die "Не удалось обратиться к GitHub API: $($_.Exception.Message)"
}

$version = $release.tag_name
Ok "Последняя версия: $version (опубликована $([datetime]$release.published_at | Get-Date -Format 'yyyy-MM-dd'))"

# Ищем VHDX-образ для Hyper-V
$asset = $release.assets | Where-Object { $_.name -like 'haos_ova-*.vhdx.zip' } | Select-Object -First 1
if (-not $asset) {
    $asset = $release.assets | Where-Object { $_.name -like '*.vhdx.*' } | Select-Object -First 1
}
if (-not $asset) {
    Die "В релизе $version не найден VHDX-образ. Доступные файлы: $(($release.assets.name) -join ', ')"
}

$sizeMB = [math]::Round($asset.size / 1MB, 1)
Ok "Образ: $($asset.name) ($sizeMB МБ)"

# ================================================================ 3. Скачивание
Step "Скачивание образа"

$archivePath = Join-Path $downloadDir $asset.name

if ((Test-Path $archivePath) -and ((Get-Item $archivePath).Length -eq $asset.size)) {
    Ok "Образ уже скачан, размер совпадает — пропускаем"
} else {
    Write-Host "    Загрузка $sizeMB МБ, это займёт несколько минут..." -ForegroundColor DarkGray
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archivePath -TimeoutSec 1800
    } catch {
        Die "Ошибка скачивания: $($_.Exception.Message)"
    }
    $sw.Stop()

    $actualSize = (Get-Item $archivePath).Length
    if ($actualSize -ne $asset.size) {
        Remove-Item $archivePath -Force
        Die "Размер не совпадает: получено $actualSize, ожидалось $($asset.size). Файл удалён, запустите скрипт снова."
    }
    $speedMBs = [math]::Round($sizeMB / $sw.Elapsed.TotalSeconds, 1)
    Ok "Скачано за $([math]::Round($sw.Elapsed.TotalMinutes,1)) мин ($speedMBs МБ/с), размер проверен"
}

# ================================================================ 4. Распаковка
Step "Распаковка образа"

$vhdxDir  = Join-Path $VMPath $VMName
New-Item -ItemType Directory -Path $vhdxDir -Force | Out-Null
$vhdxPath = Join-Path $vhdxDir "$VMName.vhdx"

if (Test-Path $vhdxPath) {
    # Образ уже распакован (например, ранее запускали с -DownloadOnly)
    Ok "VHDX уже распакован — пропускаем"
} else {
    $extractTmp = Join-Path $downloadDir 'extract'
    if (Test-Path $extractTmp) { Remove-Item $extractTmp -Recurse -Force }
    New-Item -ItemType Directory -Path $extractTmp -Force | Out-Null

    Expand-Archive -Path $archivePath -DestinationPath $extractTmp -Force
    $srcVhdx = Get-ChildItem -Path $extractTmp -Filter '*.vhdx' -Recurse | Select-Object -First 1
    if (-not $srcVhdx) { Die "В архиве не найден .vhdx файл" }

    Move-Item -Path $srcVhdx.FullName -Destination $vhdxPath -Force
    Remove-Item $extractTmp -Recurse -Force
}

$vhdxSizeGB = [math]::Round((Get-Item $vhdxPath).Length / 1GB, 2)
Ok "VHDX готов: $vhdxPath ($vhdxSizeGB ГБ)"

# Расширяем виртуальный диск до 64 ГБ (HAOS сам расширит раздел при старте)
try {
    $currentSize = (Get-VHD -Path $vhdxPath).Size
    $targetSize  = 64GB
    if ($currentSize -lt $targetSize) {
        Resize-VHD -Path $vhdxPath -SizeBytes $targetSize
        Ok "Виртуальный диск расширен до 64 ГБ"
    } else {
        Ok "Размер виртуального диска: $([math]::Round($currentSize/1GB,0)) ГБ"
    }
} catch {
    Warn "Не удалось расширить диск: $($_.Exception.Message). Продолжаем с исходным размером."
}

if ($DownloadOnly) {
    Write-Host @"

$('=' * 62)
  ОБРАЗ СКАЧАН И ГОТОВ
$('=' * 62)

  Версия HAOS:  $version
  Файл:         $vhdxPath
  Размер:       $([math]::Round((Get-Item $vhdxPath).Length / 1GB, 2)) ГБ

  Виртуальная машина НЕ создавалась (ключ -DownloadOnly).

  Дома, когда NUC будет подключён к домашней сети кабелем, запустите
  без ключа — образ уже на диске, скачиваться заново не будет:

      .\02-install-haos-vm.ps1

$('=' * 62)

"@ -ForegroundColor White

    @{ Version = $version; VhdxPath = $vhdxPath; DownloadedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') } |
        ConvertTo-Json | Out-File -FilePath (Join-Path $PSScriptRoot 'ha-image-state.json') -Encoding UTF8
    exit 0
}

# ================================================================ 5. Виртуальный коммутатор
Step "Настройка виртуального коммутатора"

$vSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($vSwitch) {
    Ok "Коммутатор '$SwitchName' уже существует (тип: $($vSwitch.SwitchType))"
} else {
    # Берём активный проводной адаптер, не виртуальный
    $nic = Get-NetAdapter |
        Where-Object {
            $_.Status -eq 'Up' -and
            $_.Virtual -eq $false -and
            $_.InterfaceDescription -notmatch 'Hyper-V|Loopback|Bluetooth'
        } |
        Sort-Object -Property @{ Expression = { if ($_.MediaType -eq '802.3') { 0 } else { 1 } } }, LinkSpeed -Descending |
        Select-Object -First 1

    if (-not $nic) { Die "Не найден активный физический сетевой адаптер" }

    Write-Host "    Адаптер: $($nic.Name) — $($nic.InterfaceDescription)" -ForegroundColor DarkGray
    Warn "Сеть на 5-10 секунд прервётся при создании коммутатора"

    New-VMSwitch -Name $SwitchName -NetAdapterName $nic.Name -AllowManagementOS $true | Out-Null
    Start-Sleep -Seconds 8
    Ok "External-коммутатор '$SwitchName' создан на адаптере '$($nic.Name)'"
}

# ================================================================ 6. Создание VM
Step "Создание виртуальной машины"

$vm = New-VM -Name $VMName `
             -Generation 2 `
             -MemoryStartupBytes ($MemoryGB * 1GB) `
             -VHDPath $vhdxPath `
             -SwitchName $SwitchName `
             -Path $VMPath
Ok "VM '$VMName' создана (Generation 2)"

# --- Secure Boot ВЫКЛЮЧИТЬ: HAOS не подписан ключами Microsoft
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Ok "Secure Boot отключён (обязательно для HAOS)"

# --- Порядок загрузки: только виртуальный диск
$bootDrive = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $bootDrive
Ok "Порядок загрузки: VHDX первым"

# --- Статическая память: HAOS плохо работает с balloon-драйвером Hyper-V
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB * 1GB)
Ok "Память: $MemoryGB ГБ статически (динамическая отключена)"

# --- Процессоры
Set-VMProcessor -VMName $VMName -Count $CPUCount
Ok "Процессоров: $CPUCount"

# --- Автоматические чекпоинты ЛОМАЮТ HAOS: разрастание диска, порча БД recorder
Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false
Ok "Автоматические чекпоинты отключены"

# --- Автостарт при загрузке Windows с задержкой (даём сети подняться)
Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStartDelay 30
Ok "Автозапуск при старте Windows (задержка 30 сек)"

# --- При выключении хоста — корректно гасить гостя, а не рубить питание
Set-VM -Name $VMName -AutomaticStopAction ShutDown
Ok "При выключении хоста: корректное завершение работы гостя"

# --- Фиксированный MAC: нужен для DHCP-резервации на роутере Eltex
$mac = '00155D' + (-join ((1..6) | ForEach-Object { '{0:X}' -f (Get-Random -Max 16) }))
Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $mac -MacAddressSpoofing On
$macFormatted = ($mac -split '(.{2})' -ne '') -join ':'
Ok "MAC-адрес зафиксирован: $macFormatted"

# --- Службы интеграции
Enable-VMIntegrationService -VMName $VMName -Name 'Heartbeat', 'Shutdown', 'Time Synchronization' -ErrorAction SilentlyContinue
# Синхронизацию времени лучше выключить: HAOS сам синхронизируется по NTP
Disable-VMIntegrationService -VMName $VMName -Name 'Time Synchronization' -ErrorAction SilentlyContinue
Ok "Службы интеграции настроены (синхронизация времени — через NTP гостя)"

# ================================================================ 7. Запуск
Step "Запуск виртуальной машины"

Start-VM -Name $VMName
Ok "VM запущена"

Write-Host "    Ожидание загрузки Home Assistant (до 10 минут)..." -ForegroundColor DarkGray

$haIp      = $null
$deadline  = (Get-Date).AddMinutes(10)
$spinner   = @('|','/','-','\')
$i         = 0

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $i++
    Write-Host "`r    $($spinner[$i % 4]) поиск HA в сети... $([int]((Get-Date) - $deadline.AddMinutes(-10)).TotalSeconds) сек" -NoNewline -ForegroundColor DarkGray

    # Способ 1: адрес от служб интеграции Hyper-V
    $vmNet = Get-VMNetworkAdapter -VMName $VMName
    $ipv4  = $vmNet.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } | Select-Object -First 1
    if ($ipv4) { $haIp = $ipv4; break }

    # Способ 2: DNS-имя по умолчанию
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses('homeassistant.local') |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($resolved) { $haIp = $resolved.IPAddressToString; break }
    } catch { }
}
Write-Host "`r" + (' ' * 70) + "`r" -NoNewline

if ($haIp) {
    Ok "Home Assistant обнаружен: $haIp"
    # Ждём готовности веб-интерфейса
    $webReady = $false
    for ($n = 0; $n -lt 30; $n++) {
        try {
            $r = Invoke-WebRequest -Uri "http://${haIp}:8123" -TimeoutSec 5 -UseBasicParsing
            if ($r.StatusCode -eq 200) { $webReady = $true; break }
        } catch { Start-Sleep -Seconds 10 }
    }
    if ($webReady) { Ok "Веб-интерфейс отвечает на http://${haIp}:8123" }
    else { Warn "VM работает, но веб-интерфейс ещё поднимается — подождите пару минут" }
} else {
    Warn "IP-адрес автоматически определить не удалось"
    Warn "Найдите его в веб-интерфейсе роутера Eltex по MAC $macFormatted"
}

# ================================================================ Итог
$summary = @"

$('=' * 62)
  УСТАНОВКА ЗАВЕРШЕНА
$('=' * 62)

  VM:              $VMName
  Версия HAOS:     $version
  Память:          $MemoryGB ГБ (статически)
  Процессоры:      $CPUCount
  Диск:            $vhdxPath
  MAC-адрес:       $macFormatted
  IP-адрес:        $(if ($haIp) { $haIp } else { 'определить не удалось' })
  Коммутатор:      $SwitchName

  ДОСТУП:
    Веб-интерфейс: http://$(if ($haIp) { $haIp } else { 'homeassistant.local' }):8123
    Консоль VM:    vmconnect.exe localhost $VMName

  СЛЕДУЮЩИЕ ШАГИ (ручные):

  1. Откройте http://$(if ($haIp) { $haIp } else { 'homeassistant.local' }):8123
     Создайте аккаунт администратора.
     Часовой пояс: Europe/Moscow

  2. Закрепите IP за VM на роутере Eltex (192.168.1.1):
        LAN -> DHCP -> Резервирование адресов
        MAC: $macFormatted  ->  IP: 192.168.1.10

  3. Запустите проверку:
        .\03-verify.ps1

  4. Настройте автовосстановление:
        .\04-setup-healthcheck.ps1

$('=' * 62)

"@

Write-Host $summary -ForegroundColor White

# Сохраняем параметры для следующих скриптов
$state = [ordered]@{
    VMName      = $VMName
    Version     = $version
    MacAddress  = $macFormatted
    IPAddress   = $haIp
    VhdxPath    = $vhdxPath
    SwitchName  = $SwitchName
    MemoryGB    = $MemoryGB
    CPUCount    = $CPUCount
    InstalledAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
$statePath = Join-Path $PSScriptRoot 'ha-vm-state.json'
$state | ConvertTo-Json | Out-File -FilePath $statePath -Encoding UTF8
Write-Host "  Параметры сохранены: $statePath`n" -ForegroundColor DarkGray
