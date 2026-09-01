<#
.SYNOPSIS
    Проверка корректности развертывания Home Assistant в Hyper-V.
.DESCRIPTION
    Проверяет 20+ пунктов: настройки VM, сеть, доступность HA,
    настройки питания хоста, Windows Update, каналы удалённого доступа.
    Ничего не меняет — только диагностика.
.NOTES
    Запускать от имени администратора.
#>

#Requires -RunAsAdministrator

param(
    [string]$VMName    = 'HomeAssistant',
    [string]$DongleIp  = '192.168.1.11'
)

$ErrorActionPreference = 'Continue'

$script:pass = 0
$script:warn = 0
$script:fail = 0

function Check {
    param(
        [string]$Name,
        [scriptblock]$Test,
        [string]$FixHint = ''
    )
    try {
        $result = & $Test
    } catch {
        $result = @{ Status = 'FAIL'; Detail = $_.Exception.Message }
    }

    $status = $result.Status
    $detail = $result.Detail

    switch ($status) {
        'PASS' { $script:pass++; $sym = '  OK '; $color = 'Green'  }
        'WARN' { $script:warn++; $sym = '  !  '; $color = 'Yellow' }
        default { $script:fail++; $sym = '  X  '; $color = 'Red'   }
    }

    Write-Host ("{0} {1,-40} {2}" -f $sym, $Name, $detail) -ForegroundColor $color
    if ($status -eq 'FAIL' -and $FixHint) {
        Write-Host ("       -> $FixHint") -ForegroundColor DarkYellow
    }
}

function Section { param([string]$t) Write-Host "`n--- $t ---" -ForegroundColor Cyan }

Write-Host "`n  ПРОВЕРКА РАЗВЕРТЫВАНИЯ HOME ASSISTANT" -ForegroundColor White
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray

# Загружаем состояние от скрипта установки
$statePath = Join-Path $PSScriptRoot 'ha-vm-state.json'
$state = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json } else { $null }

# ================================================================ Hyper-V
Section "Hyper-V"

Check "Компонент Hyper-V включён" {
    $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
    if ($hv.State -eq 'Enabled') { @{ Status='PASS'; Detail='Enabled' } }
    else { @{ Status='FAIL'; Detail=$hv.State } }
} "Запустите 01-prepare-windows.ps1 и перезагрузитесь"

Check "Служба vmms запущена" {
    $svc = Get-Service vmms -ErrorAction SilentlyContinue
    if ($svc.Status -eq 'Running') { @{ Status='PASS'; Detail='Running' } }
    else { @{ Status='FAIL'; Detail="$($svc.Status)" } }
} "Start-Service vmms"

# ================================================================ VM
Section "Виртуальная машина"

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue

Check "VM '$VMName' существует" {
    if ($vm) { @{ Status='PASS'; Detail="создана $($vm.CreationTime.ToString('yyyy-MM-dd'))" } }
    else { @{ Status='FAIL'; Detail='не найдена' } }
} "Запустите 02-install-haos-vm.ps1"

if ($vm) {
    Check "VM запущена" {
        if ($vm.State -eq 'Running') {
            $up = (Get-Date) - $vm.CreationTime
            @{ Status='PASS'; Detail="Running, uptime $($vm.Uptime.ToString('d\d\ hh\:mm'))" }
        } else { @{ Status='FAIL'; Detail=$vm.State } }
    } "Start-VM -Name $VMName"

    Check "Generation 2" {
        if ($vm.Generation -eq 2) { @{ Status='PASS'; Detail='Gen2 (UEFI)' } }
        else { @{ Status='WARN'; Detail="Gen$($vm.Generation)" } }
    }

    Check "Secure Boot отключён" {
        $fw = Get-VMFirmware -VMName $VMName
        if ($fw.SecureBoot -eq 'Off') { @{ Status='PASS'; Detail='Off — верно для HAOS' } }
        else { @{ Status='FAIL'; Detail='On — HAOS не загрузится' } }
    } "Set-VMFirmware -VMName $VMName -EnableSecureBoot Off"

    Check "Память статическая" {
        $m = Get-VMMemory -VMName $VMName
        $gb = [math]::Round($m.Startup / 1GB, 1)
        if (-not $m.DynamicMemoryEnabled) { @{ Status='PASS'; Detail="$gb ГБ статически" } }
        else { @{ Status='WARN'; Detail="$gb ГБ динамически — HAOS предпочитает статику" } }
    } "Set-VMMemory -VMName $VMName -DynamicMemoryEnabled `$false"

    Check "Памяти достаточно" {
        $gb = [math]::Round((Get-VMMemory -VMName $VMName).Startup / 1GB, 1)
        if ($gb -ge 4)   { @{ Status='PASS'; Detail="$gb ГБ" } }
        elseif ($gb -ge 2) { @{ Status='WARN'; Detail="$gb ГБ — маловато при росте БД" } }
        else { @{ Status='FAIL'; Detail="$gb ГБ — критично мало" } }
    }

    Check "Автозапуск включён" {
        if ($vm.AutomaticStartAction -eq 'Start') {
            @{ Status='PASS'; Detail="Start, задержка $($vm.AutomaticStartDelay) сек" }
        } else { @{ Status='FAIL'; Detail=$vm.AutomaticStartAction } }
    } "Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStartDelay 30"

    Check "Корректное завершение при выключении хоста" {
        if ($vm.AutomaticStopAction -eq 'ShutDown') { @{ Status='PASS'; Detail='ShutDown' } }
        else { @{ Status='WARN'; Detail="$($vm.AutomaticStopAction) — риск повреждения БД" } }
    } "Set-VM -Name $VMName -AutomaticStopAction ShutDown"

    Check "Авточекпоинты отключены" {
        if (-not $vm.AutomaticCheckpointsEnabled) { @{ Status='PASS'; Detail='Disabled' } }
        else { @{ Status='FAIL'; Detail='Enabled — разрастание диска и порча БД' } }
    } "Set-VM -Name $VMName -AutomaticCheckpointsEnabled `$false"

    Check "Чекпоинтов не накопилось" {
        $snaps = Get-VMSnapshot -VMName $VMName -ErrorAction SilentlyContinue
        $n = ($snaps | Measure-Object).Count
        if ($n -eq 0) { @{ Status='PASS'; Detail='нет' } }
        elseif ($n -le 2) { @{ Status='WARN'; Detail="$n шт." } }
        else { @{ Status='FAIL'; Detail="$n шт. — удалите лишние" } }
    } "Get-VMSnapshot -VMName $VMName | Remove-VMSnapshot"

    Check "MAC-адрес зафиксирован" {
        $na = Get-VMNetworkAdapter -VMName $VMName
        if ($na.DynamicMacAddressEnabled -eq $false) {
            $m = ($na.MacAddress -split '(.{2})' -ne '') -join ':'
            @{ Status='PASS'; Detail=$m }
        } else { @{ Status='WARN'; Detail='динамический — IP может смениться' } }
    }

    Check "Сетевой адаптер подключён" {
        $na = Get-VMNetworkAdapter -VMName $VMName
        if ($na.SwitchName) { @{ Status='PASS'; Detail="коммутатор '$($na.SwitchName)'" } }
        else { @{ Status='FAIL'; Detail='не подключён' } }
    }

    Check "Heartbeat от гостя" {
        $hb = Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue
        if ($hb.PrimaryStatusDescription -eq 'OK') { @{ Status='PASS'; Detail='OK' } }
        elseif ($vm.State -ne 'Running') { @{ Status='WARN'; Detail='VM не запущена' } }
        else { @{ Status='WARN'; Detail="$($hb.PrimaryStatusDescription)" } }
    }

    Check "Размер VHDX" {
        $d = Get-VMHardDiskDrive -VMName $VMName
        $vhd = Get-VHD -Path $d.Path -ErrorAction SilentlyContinue
        if ($vhd) {
            $usedGB = [math]::Round($vhd.FileSize / 1GB, 1)
            $maxGB  = [math]::Round($vhd.Size / 1GB, 0)
            @{ Status='PASS'; Detail="$usedGB ГБ на диске из $maxGB ГБ виртуальных" }
        } else { @{ Status='WARN'; Detail='не удалось прочитать' } }
    }
}

# ================================================================ Сеть
Section "Сеть"

Check "External-коммутатор существует" {
    $sw = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue
    if ($sw) { @{ Status='PASS'; Detail=(($sw | ForEach-Object { $_.Name }) -join ', ') } }
    else { @{ Status='FAIL'; Detail='нет External-коммутатора' } }
} "Запустите 02-install-haos-vm.ps1"

$haIp = $null
if ($vm -and $vm.State -eq 'Running') {
    $haIp = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } |
            Select-Object -First 1
}
if (-not $haIp -and $state) { $haIp = $state.IPAddress }

Check "IP-адрес Home Assistant" {
    if ($haIp) { @{ Status='PASS'; Detail=$haIp }
    } else { @{ Status='WARN'; Detail='не определён — проверьте DHCP на Eltex' } }
}

if ($haIp) {
    Check "Веб-интерфейс HA (:8123)" {
        try {
            $r = Invoke-WebRequest -Uri "http://${haIp}:8123" -TimeoutSec 10 -UseBasicParsing
            @{ Status='PASS'; Detail="HTTP $($r.StatusCode)" }
        } catch {
            @{ Status='FAIL'; Detail='не отвечает' }
        }
    } "Проверьте консоль VM: vmconnect.exe localhost $VMName"
}

Check "SONOFF Dongle Max ($DongleIp)" {
    if (Test-Connection -ComputerName $DongleIp -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        @{ Status='PASS'; Detail='ping отвечает' }
    } else { @{ Status='WARN'; Detail='не отвечает — проверьте PoE и кабель' } }
}

Check "Порт ser2net 6638 на донгле" {
    $t = Test-NetConnection -ComputerName $DongleIp -Port 6638 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if ($t.TcpTestSucceeded) { @{ Status='PASS'; Detail='открыт' } }
    else { @{ Status='WARN'; Detail='закрыт — Zigbee2MQTT не подключится' } }
} "Проверьте веб-интерфейс донгла: http://$DongleIp"

# ================================================================ Питание хоста
Section "Электропитание хоста"

Check "Гибернация отключена" {
    if (-not (Test-Path "$env:SystemDrive\hiberfil.sys")) { @{ Status='PASS'; Detail='hiberfil.sys отсутствует' } }
    else { @{ Status='FAIL'; Detail='hiberfil.sys существует' } }
} "powercfg /hibernate off"

Check "Спящий режим отключён (сеть)" {
    $out = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null | Out-String
    if ($out -match 'Current AC Power Setting Index:\s*0x00000000') { @{ Status='PASS'; Detail='никогда' } }
    else { @{ Status='FAIL'; Detail='таймаут задан' } }
} "powercfg /change standby-timeout-ac 0"

Check "План питания" {
    $s = (powercfg /getactivescheme) -replace '.*\(([^)]+)\).*', '$1'
    if ($s -match 'High|Высок|Ultimate') { @{ Status='PASS'; Detail=$s } }
    else { @{ Status='WARN'; Detail=$s } }
} "powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"

Check "Свободное место на C:" {
    $free = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 1)
    if ($free -ge 40)   { @{ Status='PASS'; Detail="$free ГБ" } }
    elseif ($free -ge 15) { @{ Status='WARN'; Detail="$free ГБ — скоро понадобится очистка" } }
    else { @{ Status='FAIL'; Detail="$free ГБ — критично" } }
} "Очистите диск: cleanmgr.exe"

# ================================================================ Windows Update
Section "Windows Update"

Check "Автоперезагрузка запрещена" {
    $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $v = (Get-ItemProperty -Path $p -Name NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue).NoAutoRebootWithLoggedOnUsers
    if ($v -eq 1) { @{ Status='PASS'; Detail='запрещена' } }
    else { @{ Status='WARN'; Detail='разрешена — риск ночной перезагрузки' } }
} "Запустите 01-prepare-windows.ps1"

Check "Обновления отложены" {
    $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $q = (Get-ItemProperty -Path $p -Name DeferQualityUpdatesPeriodInDays -ErrorAction SilentlyContinue).DeferQualityUpdatesPeriodInDays
    if ($q -ge 7) { @{ Status='PASS'; Detail="качественные на $q дн." } }
    else { @{ Status='WARN'; Detail='не отложены' } }
}

Check "Перезагрузка не ожидается" {
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    if (-not $pending) { @{ Status='PASS'; Detail='нет' } }
    else { @{ Status='WARN'; Detail='система ждёт перезагрузки' } }
}

# ================================================================ Удалённый доступ
Section "Удалённый доступ"

Check "RDP включён" {
    $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections).fDenyTSConnections
    if ($v -eq 0) { @{ Status='PASS'; Detail='порт 3389' } }
    else { @{ Status='WARN'; Detail='отключён' } }
} "Запустите 01-prepare-windows.ps1"

Check "RDP ограничен локальной сетью" {
    $rules = Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue |
             Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' }
    if (-not $rules) { return @{ Status='WARN'; Detail='правила не найдены' } }
    $scopes = $rules | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress -Unique
    if ($scopes -contains 'LocalSubnet') { @{ Status='PASS'; Detail='только LocalSubnet' } }
    else { @{ Status='WARN'; Detail="область: $($scopes -join ', ')" } }
}

Check "МойАссистент установлен" {
    $found = @(
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.DisplayName -match 'Ассистент|Assistant' }
    )
    $proc = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'assistant|ассистент' }
    if ($found -or $proc) {
        $n = if ($found) { $found[0].DisplayName } else { $proc[0].ProcessName }
        @{ Status='PASS'; Detail=$n }
    } else {
        @{ Status='WARN'; Detail='не обнаружен — установите вручную' }
    }
} "Скачайте с мойассистент.рф и настройте постоянный пароль"

Check "Health-check задача настроена" {
    $t = Get-ScheduledTask -TaskName 'HA-VM-HealthCheck' -ErrorAction SilentlyContinue
    if ($t -and $t.State -ne 'Disabled') { @{ Status='PASS'; Detail=$t.State } }
    else { @{ Status='WARN'; Detail='не настроена' } }
} "Запустите 04-setup-healthcheck.ps1"

# ================================================================ Итог
$total = $script:pass + $script:warn + $script:fail
Write-Host "`n" + ('=' * 62) -ForegroundColor DarkGray
Write-Host ("  ИТОГ:  {0} пройдено   {1} предупреждений   {2} ошибок   (всего {3})" -f
    $script:pass, $script:warn, $script:fail, $total) -ForegroundColor White
Write-Host ('=' * 62) -ForegroundColor DarkGray

if ($script:fail -eq 0 -and $script:warn -eq 0) {
    Write-Host "`n  Всё в порядке. Система готова к настройке Home Assistant.`n" -ForegroundColor Green
} elseif ($script:fail -eq 0) {
    Write-Host "`n  Критических проблем нет. Просмотрите предупреждения выше.`n" -ForegroundColor Yellow
} else {
    Write-Host "`n  Есть критические проблемы — исправьте их по подсказкам выше.`n" -ForegroundColor Red
}

if ($haIp) {
    Write-Host "  Home Assistant:  http://${haIp}:8123" -ForegroundColor Cyan
    Write-Host "  Консоль VM:      vmconnect.exe localhost $VMName`n" -ForegroundColor Cyan
}
