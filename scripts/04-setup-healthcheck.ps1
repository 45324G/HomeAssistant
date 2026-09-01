<#
.SYNOPSIS
    Настройка автоматического мониторинга и восстановления VM Home Assistant.
.DESCRIPTION
    Создаёт скрипт проверки и задачу в Планировщике Windows, которая каждые 15 минут:
      - проверяет что VM запущена, при необходимости запускает
      - проверяет что веб-интерфейс HA отвечает
      - при зависании (веб не отвечает 3 проверки подряд) — перезапускает VM
      - следит за свободным местом на диске
      - пишет всё в ротируемый лог
    Задача выполняется от SYSTEM, работает без входа пользователя.
.NOTES
    Запускать от имени администратора.
#>

#Requires -RunAsAdministrator

param(
    [string]$VMName          = 'HomeAssistant',
    [int]   $IntervalMinutes = 15,
    [int]   $LowDiskGB       = 15,
    [string]$TaskName        = 'HA-VM-HealthCheck'
)

$ErrorActionPreference = 'Stop'

function Step { param([string]$t) Write-Host "`n[*] $t" -ForegroundColor Cyan }
function Ok   { param([string]$t) Write-Host "    OK  $t" -ForegroundColor Green }

Write-Host "`n  НАСТРОЙКА АВТОМОНИТОРИНГА HOME ASSISTANT" -ForegroundColor White

$workDir = 'C:\HyperV\healthcheck'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# ================================================================ Скрипт проверки
Step "Создание скрипта проверки"

$checkScript = @'
<#
    Health-check для VM Home Assistant.
    Запускается Планировщиком Windows. Не редактировать вручную —
    пересоздаётся скриптом 04-setup-healthcheck.ps1.
#>
param(
    [string]$VMName    = '__VMNAME__',
    [int]   $LowDiskGB = __LOWDISK__
)

$ErrorActionPreference = 'Continue'
$workDir   = 'C:\HyperV\healthcheck'
$logFile   = Join-Path $workDir 'healthcheck.log'
$stateFile = Join-Path $workDir 'state.json'

function Log {
    param([string]$Level, [string]$Message)
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# --- Ротация лога: > 5 МБ -> переименовать
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 5MB)) {
    $archive = Join-Path $workDir "healthcheck-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Move-Item $logFile $archive -Force
    # Держим не больше 5 архивов
    Get-ChildItem $workDir -Filter 'healthcheck-*.log' |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force
}

# --- Состояние между запусками (счётчик подряд неудачных проверок веба)
$state = if (Test-Path $stateFile) {
    try { Get-Content $stateFile -Raw | ConvertFrom-Json } catch { $null }
} else { $null }
$webFailStreak = if ($state -and $state.WebFailStreak) { [int]$state.WebFailStreak } else { 0 }
$lastRestart   = if ($state -and $state.LastRestart)   { [datetime]$state.LastRestart } else { [datetime]::MinValue }

# ================================================================ 1. VM существует?
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Log 'ERROR' "VM '$VMName' не найдена. Проверка прервана."
    exit 1
}

# ================================================================ 2. VM запущена?
if ($vm.State -ne 'Running') {
    Log 'WARN' "VM в состоянии '$($vm.State)' — запускаю"
    try {
        Start-VM -Name $VMName -ErrorAction Stop
        Log 'INFO' 'VM запущена успешно'
        # Даём время на загрузку, дальнейшие проверки — в следующем цикле
        @{ WebFailStreak = 0; LastRestart = (Get-Date).ToString('o') } |
            ConvertTo-Json | Out-File $stateFile -Encoding UTF8
        exit 0
    } catch {
        Log 'ERROR' "Не удалось запустить VM: $($_.Exception.Message)"
        exit 1
    }
}

# ================================================================ 3. Веб-интерфейс отвечает?
$haIp = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } |
        Select-Object -First 1

$webOk = $false
if ($haIp) {
    try {
        $r = Invoke-WebRequest -Uri "http://${haIp}:8123" -TimeoutSec 15 -UseBasicParsing
        $webOk = ($r.StatusCode -eq 200)
    } catch {
        $webOk = $false
    }
} else {
    Log 'WARN' 'IP-адрес VM не определён'
}

if ($webOk) {
    if ($webFailStreak -gt 0) {
        Log 'INFO' "Home Assistant снова отвечает ($haIp) после $webFailStreak неудачных проверок"
    }
    $webFailStreak = 0
} else {
    $webFailStreak++
    Log 'WARN' "Home Assistant не отвечает (попытка $webFailStreak из 3), IP: $(if($haIp){$haIp}else{'неизвестен'})"
}

# ================================================================ 4. Перезапуск при зависании
# 3 неудачи подряд = ~45 минут недоступности. Не чаще одного раза в 2 часа.
if ($webFailStreak -ge 3) {
    $sinceRestart = (Get-Date) - $lastRestart
    if ($sinceRestart.TotalHours -ge 2) {
        Log 'ERROR' 'Home Assistant не отвечает 3 проверки подряд — перезапуск VM'
        try {
            Stop-VM -Name $VMName -Force -ErrorAction Stop
            Start-Sleep -Seconds 15
            Start-VM -Name $VMName -ErrorAction Stop
            Log 'INFO' 'VM перезапущена'
            $lastRestart   = Get-Date
            $webFailStreak = 0
        } catch {
            Log 'ERROR' "Перезапуск не удался: $($_.Exception.Message)"
        }
    } else {
        Log 'WARN' ("Перезапуск отложен — последний был {0:N1} ч назад (минимум 2 ч)" -f $sinceRestart.TotalHours)
    }
}

# ================================================================ 5. Свободное место
$freeGB = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 1)
if ($freeGB -lt $LowDiskGB) {
    Log 'WARN' "Мало места на C: $freeGB ГБ (порог $LowDiskGB ГБ)"
}

# ================================================================ 6. Размер VHDX
try {
    $vhdPath = (Get-VMHardDiskDrive -VMName $VMName).Path
    $vhdGB   = [math]::Round((Get-Item $vhdPath).Length / 1GB, 1)
} catch { $vhdGB = 0 }

# ================================================================ 7. Итоговая строка состояния
$memGB = [math]::Round($vm.MemoryAssigned / 1GB, 1)
Log 'INFO' ("state=$($vm.State) ip=$(if($haIp){$haIp}else{'-'}) web=$(if($webOk){'ok'}else{'FAIL'}) " +
            "uptime=$($vm.Uptime.ToString('d\d\ hh\:mm')) mem=${memGB}GB vhdx=${vhdGB}GB freeC=${freeGB}GB")

# --- Сохраняем состояние
@{
    WebFailStreak = $webFailStreak
    LastRestart   = $lastRestart.ToString('o')
    LastCheck     = (Get-Date).ToString('o')
    LastStatus    = if ($webOk) { 'OK' } else { 'FAIL' }
} | ConvertTo-Json | Out-File $stateFile -Encoding UTF8
'@

$checkScript = $checkScript -replace '__VMNAME__', $VMName -replace '__LOWDISK__', $LowDiskGB
$checkPath = Join-Path $workDir 'Check-HAVM.ps1'
$checkScript | Out-File -FilePath $checkPath -Encoding UTF8
Ok "Скрипт: $checkPath"

# ================================================================ Задача планировщика
Step "Создание задачи в Планировщике Windows"

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$checkPath`""

# Два триггера: при старте системы (с задержкой) и по расписанию
$triggerBoot = New-ScheduledTaskTrigger -AtStartup
$triggerBoot.Delay = 'PT3M'   # 3 минуты после загрузки — даём VM подняться

$triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $action `
    -Trigger     @($triggerBoot, $triggerRepeat) `
    -Principal   $principal `
    -Settings    $settings `
    -Description "Мониторинг и автовосстановление VM Home Assistant. Создано скриптом 04-setup-healthcheck.ps1" | Out-Null

Ok "Задача '$TaskName' зарегистрирована"
Ok "Интервал: каждые $IntervalMinutes минут + при загрузке системы"
Ok "Запуск от: SYSTEM (работает без входа пользователя)"

# ================================================================ Первый запуск
Step "Первый запуск проверки"
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 20

$logFile = Join-Path $workDir 'healthcheck.log'
if (Test-Path $logFile) {
    Ok "Лог создан, последние записи:"
    Get-Content $logFile -Tail 5 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
} else {
    Write-Host "    !   Лог пока пуст — проверка ещё выполняется" -ForegroundColor Yellow
}

# ================================================================ Вспомогательные команды
$helperPath = Join-Path $workDir 'ha-status.ps1'
@"
# Быстрый статус Home Assistant. Запуск: powershell -File C:\HyperV\healthcheck\ha-status.ps1
`$vm = Get-VM -Name '$VMName' -ErrorAction SilentlyContinue
if (-not `$vm) { Write-Host 'VM не найдена' -ForegroundColor Red; exit 1 }

`$ip = (Get-VMNetworkAdapter -VMName '$VMName').IPAddresses |
       Where-Object { `$_ -match '^\d+\.\d+\.\d+\.\d+`$' -and `$_ -notlike '169.254.*' } | Select-Object -First 1

Write-Host ''
Write-Host "  VM:      `$(`$vm.Name) — `$(`$vm.State)" -ForegroundColor Cyan
Write-Host "  Uptime:  `$(`$vm.Uptime.ToString('d\d\ hh\:mm\:ss'))"
Write-Host "  Память:  `$([math]::Round(`$vm.MemoryAssigned/1GB,1)) ГБ"
Write-Host "  CPU:     `$(`$vm.CPUUsage)%"
Write-Host "  IP:      `$(if(`$ip){`$ip}else{'не определён'})"
if (`$ip) { Write-Host "  Web:     http://`$ip`:8123" -ForegroundColor Green }
Write-Host ''
Write-Host '  Последние проверки:' -ForegroundColor DarkGray
Get-Content 'C:\HyperV\healthcheck\healthcheck.log' -Tail 8 -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "    `$_" -ForegroundColor DarkGray }
Write-Host ''
"@ | Out-File -FilePath $helperPath -Encoding UTF8

Write-Host @"

$('=' * 62)
  АВТОМОНИТОРИНГ НАСТРОЕН
$('=' * 62)

  Что делает каждые $IntervalMinutes минут:
    - запускает VM, если она остановлена
    - проверяет отклик http://<ip>:8123
    - перезапускает VM при 3 неудачах подряд (не чаще 1 раза в 2 ч)
    - следит за свободным местом (порог $LowDiskGB ГБ)
    - пишет лог с ротацией

  Полезные команды:

    Быстрый статус:
      powershell -File $helperPath

    Смотреть лог в реальном времени:
      Get-Content C:\HyperV\healthcheck\healthcheck.log -Wait -Tail 20

    Запустить проверку немедленно:
      Start-ScheduledTask -TaskName $TaskName

    Отключить мониторинг:
      Disable-ScheduledTask -TaskName $TaskName

    Удалить совсем:
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false

$('=' * 62)

"@ -ForegroundColor White
