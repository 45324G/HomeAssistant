<#
.SYNOPSIS
    Диагностика Zigbee-донгла, подключённого по USB, и готовности хоста.
.DESCRIPTION
    Собирает всё, что нужно для настройки Zigbee2MQTT и выбора способа
    проброса донгла в виртуальную машину:
      - COM-порт и его номер
      - VID/PID и модель USB-UART моста (определяет тип адаптера в Z2M)
      - состояние драйвера
      - проблемные устройства
      - состояние Hyper-V и виртуальных машин
      - наличие usbipd-win (для проброса USB в VM)
    Ничего не меняет. Отчёт сохраняется на Рабочий стол.
.NOTES
    Права администратора НЕ требуются для основной части.
#>

[CmdletBinding()]
param(
    [string]$OutFile = "$env:USERPROFILE\Desktop\zigbee-report.txt"
)

$ErrorActionPreference = 'Continue'
$report = [System.Collections.Generic.List[string]]::new()

function Add-Line {
    param([string]$Text, [string]$Color = 'Gray')
    $report.Add($Text)
    Write-Host $Text -ForegroundColor $Color
}
function Add-Header {
    param([string]$Title)
    $report.Add('')
    $report.Add("### $Title")
    Write-Host ''
    Write-Host "### $Title" -ForegroundColor Cyan
}

Add-Line "=== ДИАГНОСТИКА ZIGBEE USB ===" 'White'
Add-Line "Дата:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "Компьютер: $env:COMPUTERNAME"
Add-Line "ОС:        $((Get-CimInstance Win32_OperatingSystem).Caption) build $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"

# ================================================================ COM-порты
Add-Header 'COM-ПОРТЫ'

$serialPorts = @(Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue)
if ($serialPorts) {
    foreach ($p in $serialPorts) {
        Add-Line "  $($p.DeviceID) | $($p.Description)" 'Green'
        Add-Line "      PNPDeviceID: $($p.PNPDeviceID)"
        Add-Line "      Статус:      $($p.Status)"
    }
} else {
    Add-Line "  Win32_SerialPort ничего не вернул (нормально для USB-CDC устройств)" 'Yellow'
}

# Дублирующий способ — через класс Ports
Add-Header 'УСТРОЙСТВА КЛАССА Ports (COM и LPT)'
$portDevices = @(Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue)
if ($portDevices) {
    foreach ($d in $portDevices) {
        $color = if ($d.Status -eq 'OK') { 'Green' } else { 'Red' }
        Add-Line "  [$($d.Status)] $($d.FriendlyName)" $color
        Add-Line "      InstanceId: $($d.InstanceId)"
    }
} else {
    Add-Line "  Устройств класса Ports не найдено" 'Red'
    Add-Line "  -> Донгл не распознан. Нужен драйвер или другой USB-порт/кабель." 'Yellow'
}

# ================================================================ Поиск донгла по сигнатурам
Add-Header 'ПОИСК ZIGBEE-ДОНГЛА ПО ИЗВЕСТНЫМ СИГНАТУРАМ'

# Известные USB-UART мосты, применяемые в Zigbee-координаторах
$knownBridges = @{
    'VID_10C4&PID_EA60' = 'Silicon Labs CP2102/CP2102N  (SONOFF ZBDongle-E/M, многие EFR32)'
    'VID_10C4&PID_EA70' = 'Silicon Labs CP2105 (двухканальный)'
    'VID_1A86&PID_7523' = 'WCH CH340  (SONOFF ZBDongle-P и клоны)'
    'VID_1A86&PID_55D4' = 'WCH CH9102 (новые ревизии)'
    'VID_0403&PID_6001' = 'FTDI FT232R'
    'VID_1CF1&PID_0030' = 'Dresden Elektronik ConBee II'
    'VID_303A'          = 'Espressif (ESP32-based координаторы)'
    'VID_2FE3'          = 'Nordic / generic USB CDC'
}

$allUsb = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^USB\\VID_' })
$found = $false

foreach ($sig in $knownBridges.Keys) {
    $matches = $allUsb | Where-Object { $_.InstanceId -match [regex]::Escape($sig) }
    foreach ($m in $matches) {
        $found = $true
        Add-Line "  НАЙДЕНО: $($knownBridges[$sig])" 'Green'
        Add-Line "      Имя:        $($m.FriendlyName)"
        Add-Line "      Статус:     $($m.Status)"
        Add-Line "      Класс:      $($m.Class)"
        Add-Line "      InstanceId: $($m.InstanceId)"

        # Достаём номер COM-порта из реестра
        try {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($m.InstanceId)\Device Parameters"
            $portName = (Get-ItemProperty -Path $regPath -Name PortName -ErrorAction Stop).PortName
            Add-Line "      COM-ПОРТ:   $portName" 'Green'
        } catch {
            Add-Line "      COM-порт из реестра прочитать не удалось" 'Yellow'
        }

        # Версия и поставщик драйвера
        try {
            $drvVer = (Get-PnpDeviceProperty -InstanceId $m.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction Stop).Data
            $drvPrv = (Get-PnpDeviceProperty -InstanceId $m.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction Stop).Data
            $drvDat = (Get-PnpDeviceProperty -InstanceId $m.InstanceId -KeyName 'DEVPKEY_Device_DriverDate' -ErrorAction SilentlyContinue).Data
            Add-Line "      Драйвер:    $drvPrv v$drvVer $(if($drvDat){"от $($drvDat.ToString('yyyy-MM-dd'))"})"
        } catch { }
    }
}

if (-not $found) {
    Add-Line "  Известных USB-UART мостов не найдено." 'Yellow'
    Add-Line "  Смотрите полный список USB-устройств ниже — донгл может быть там" 'Yellow'
    Add-Line "  под нестандартным VID/PID." 'Yellow'
}

# ================================================================ Все USB-устройства
Add-Header 'ВСЕ USB-УСТРОЙСТВА (VID/PID)'
if ($allUsb) {
    foreach ($d in ($allUsb | Sort-Object Class, FriendlyName)) {
        $color = if ($d.Status -eq 'OK') { 'Gray' } else { 'Red' }
        Add-Line "  [$($d.Status)] $($d.Class.PadRight(14)) $($d.FriendlyName)" $color
        Add-Line "      $($d.InstanceId)"
    }
} else {
    Add-Line "  Список пуст" 'Red'
}

# ================================================================ Проблемные устройства
Add-Header 'УСТРОЙСТВА С ПРОБЛЕМАМИ'
$bad = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -notin @('OK', 'Unknown') })
if ($bad) {
    foreach ($d in $bad) {
        Add-Line "  [$($d.Status)] $($d.Class) | $($d.FriendlyName)" 'Red'
        Add-Line "      $($d.InstanceId)"
        try {
            $problem = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction Stop).Data
            Add-Line "      Код проблемы: $problem" 'Red'
        } catch { }
    }
} else {
    Add-Line "  Проблемных устройств нет" 'Green'
}

# ================================================================ Проверка занятости COM-порта
Add-Header 'ДОСТУПНОСТЬ COM-ПОРТОВ'
$comNames = [System.IO.Ports.SerialPort]::GetPortNames()
if ($comNames) {
    Add-Line "  .NET видит порты: $($comNames -join ', ')" 'Green'
    foreach ($c in $comNames) {
        try {
            $sp = New-Object System.IO.Ports.SerialPort $c, 115200
            $sp.Open()
            $sp.Close()
            $sp.Dispose()
            Add-Line "  $c — свободен, открывается на 115200 бод" 'Green'
        } catch {
            Add-Line "  $c — занят или недоступен: $($_.Exception.Message.Split([Environment]::NewLine)[0])" 'Yellow'
        }
    }
} else {
    Add-Line "  .NET не видит ни одного COM-порта" 'Red'
}

# ================================================================ Hyper-V
Add-Header 'HYPER-V И ВИРТУАЛЬНЫЕ МАШИНЫ'
try {
    $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
    Add-Line "  Компонент Hyper-V: $($hv.State)" $(if ($hv.State -eq 'Enabled') { 'Green' } else { 'Yellow' })
} catch {
    Add-Line "  Состояние Hyper-V определить не удалось (нужны права администратора)" 'Yellow'
}

$vms = @(Get-VM -ErrorAction SilentlyContinue)
if ($vms) {
    foreach ($v in $vms) {
        Add-Line "  VM: $($v.Name) | $($v.State) | Gen$($v.Generation) | $([math]::Round($v.MemoryAssigned/1GB,1)) ГБ"
    }
} else {
    Add-Line "  Виртуальных машин нет"
}

$switches = @(Get-VMSwitch -ErrorAction SilentlyContinue)
if ($switches) {
    foreach ($s in $switches) {
        Add-Line "  vSwitch: $($s.Name) | тип $($s.SwitchType) | адаптер: $($s.NetAdapterInterfaceDescription)"
    }
}

# ================================================================ usbipd-win
Add-Header 'USBIPD-WIN (проброс USB в виртуальную машину)'
$usbipd = Get-Command usbipd -ErrorAction SilentlyContinue
if ($usbipd) {
    Add-Line "  Установлен: $($usbipd.Source)" 'Green'
    try {
        $list = & usbipd list 2>&1 | Out-String
        Add-Line "  Вывод 'usbipd list':"
        $list -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Add-Line "      $($_.TrimEnd())" }
    } catch {
        Add-Line "  Не удалось выполнить 'usbipd list': $($_.Exception.Message)" 'Yellow'
    }
} else {
    Add-Line "  Не установлен." 'Yellow'
    Add-Line "  Это единственный способ пробросить USB-донгл в VM под Hyper-V." 'Yellow'
    Add-Line "  Установка: winget install usbipd" 'Yellow'
}

# ================================================================ Сеть
Add-Header 'СЕТЬ'
foreach ($n in (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
    $ip = (Get-NetIPAddress -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    Add-Line "  $($n.Name) | $($n.InterfaceDescription)"
    Add-Line "      MAC: $($n.MacAddress) | Скорость: $($n.LinkSpeed) | IP: $($ip -join ', ')"
}

# Проверяем, доступен ли донгл ещё и по сети (у Dongle Max есть Ethernet)
Add-Header 'ПРОВЕРКА СЕТЕВОГО РЕЖИМА ДОНГЛА'
foreach ($testIp in @('192.168.1.11', '192.168.0.11')) {
    $alive = Test-Connection -ComputerName $testIp -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($alive) {
        Add-Line "  $testIp — отвечает на ping" 'Green'
        $tcp = Test-NetConnection -ComputerName $testIp -Port 6638 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        Add-Line "      Порт 6638 (ser2net): $(if ($tcp.TcpTestSucceeded) { 'открыт' } else { 'закрыт' })" `
                 $(if ($tcp.TcpTestSucceeded) { 'Green' } else { 'Yellow' })
    } else {
        Add-Line "  $testIp — не отвечает"
    }
}

# ================================================================ Сохранение
$report | Out-File -FilePath $OutFile -Encoding UTF8

Write-Host ''
Write-Host ('=' * 64) -ForegroundColor DarkGray
Write-Host "  Отчёт сохранён: $OutFile" -ForegroundColor Green
Write-Host "  Отправьте содержимое этого файла в чат." -ForegroundColor Green
Write-Host ('=' * 64) -ForegroundColor DarkGray
Write-Host ''

# Открываем в блокноте для удобного копирования
try { Start-Process notepad.exe -ArgumentList $OutFile } catch { }
