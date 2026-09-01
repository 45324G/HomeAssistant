> ⚠️ **УСТАРЕЛО.** Скрипты написаны под Windows + Hyper-V — этот вариант отменён.
> Актуальная архитектура (Proxmox + HAOS) — в [../MASTER_PLAN.md](../MASTER_PLAN.md).

---

# Скрипты автоматизации

PowerShell-скрипты для развертывания Home Assistant OS в Hyper-V на Windows 11 Pro.

## Требования

- Windows 10/11 **Pro**, Enterprise или Education (в Home нет Hyper-V)
- Права администратора
- VT-x включена в BIOS
- ≥ 40 ГБ свободного места
- Проводное подключение к сети

## Порядок запуска

```powershell
# PowerShell от имени администратора
cd C:\HomeAssistant\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

.\00-audit-system.ps1        # аудит, ничего не меняет
.\01-prepare-windows.ps1     # питание, Windows Update, RDP, Hyper-V -> перезагрузка
.\02-install-haos-vm.ps1     # скачивание HAOS + создание и запуск VM
.\03-verify.ps1              # проверка 25 пунктов
.\04-setup-healthcheck.ps1   # автомониторинг и восстановление
```

Между шагами 1 и 2 — перезагрузка и ручная установка МойАссистент.

## Что делает каждый скрипт

### `00-audit-system.ps1`
Только чтение. Собирает данные о CPU, RAM, дисках, сети, готовности Hyper-V,
проверяет доступность SONOFF Dongle Max на `192.168.1.11:6638`.
Пишет `audit-report.txt`. Помечает блокеры как `[FAIL]`.

### `01-prepare-windows.ps1`
- План питания High Performance, гибернация off, все таймауты сна = 0
- USB selective suspend off, кнопка питания обезврежена
- Управление питанием сетевых адаптеров отключено
- Windows Update: функциональные обновления +365 дней, качественные +30,
  автоперезагрузка при активном пользователе запрещена, активные часы 06:00–00:00
- RDP включён, ограничен `LocalSubnet`, NLA включена
- Профиль сети → Private
- Hyper-V включён

Требует перезагрузки.

### `02-install-haos-vm.ps1`
- Определяет последний релиз HAOS через GitHub API
- Скачивает `haos_ova-*.vhdx.zip`, сверяет размер, распаковывает
- Расширяет VHDX до 64 ГБ
- Создаёт External vSwitch на физическом адаптере
- Создаёт VM Gen2: Secure Boot **Off**, статические 4 ГБ, 2 vCPU,
  авточекпоинты **Off**, автозапуск с задержкой 30 сек, `AutomaticStopAction = ShutDown`
- Фиксирует MAC-адрес
- Запускает VM и ждёт отклика на `:8123` (до 10 минут)
- Пишет `ha-vm-state.json`

Параметры: `-VMName`, `-MemoryGB`, `-CPUCount`, `-VMPath`, `-SwitchName`.

Идемпотентен: при существующей VM спрашивает подтверждение `DELETE`.

### `03-verify.ps1`
25 проверок: Hyper-V, настройки VM, сеть, доступность HA и донгла,
питание хоста, политики Windows Update, каналы удалённого доступа,
наличие МойАссистент, задача health-check.
Для каждого `FAIL` печатает команду исправления.

### `04-setup-healthcheck.ps1`
Создаёт `C:\HyperV\healthcheck\Check-HAVM.ps1` и задачу планировщика
`HA-VM-HealthCheck` (от SYSTEM, каждые 15 минут + при загрузке):

- запускает VM, если остановлена
- проверяет отклик `http://<ip>:8123`
- перезапускает VM после 3 неудач подряд, не чаще раза в 2 часа
- следит за свободным местом
- лог с ротацией по 5 МБ, хранится 5 архивов

Параметры: `-VMName`, `-IntervalMinutes`, `-LowDiskGB`, `-TaskName`.

## Полезные команды

```powershell
# Быстрый статус
powershell -File C:\HyperV\healthcheck\ha-status.ps1

# Лог мониторинга в реальном времени
Get-Content C:\HyperV\healthcheck\healthcheck.log -Wait -Tail 20

# Консоль VM
vmconnect.exe localhost HomeAssistant

# IP виртуалки
(Get-VMNetworkAdapter -VMName HomeAssistant).IPAddresses

# Перезапуск
Restart-VM -Name HomeAssistant

# Отключить мониторинг
Disable-ScheduledTask -TaskName HA-VM-HealthCheck
```

## Ключевые технические решения

| Настройка | Значение | Причина |
|-----------|----------|---------|
| Generation | 2 (UEFI) | Требование современного HAOS |
| Secure Boot | **Off** | HAOS не подписан ключами Microsoft — иначе не загрузится |
| Память | Статическая | HAOS плохо работает с balloon-драйвером Hyper-V |
| Авточекпоинты | **Off** | Разрастание диска и повреждение БД recorder |
| `AutomaticStopAction` | ShutDown | Резкое выключение повреждает SQLite-базу HA |
| MAC | Статический | Нужен для DHCP-резервации на Eltex |
| Проброс USB | Не используется | SONOFF Dongle Max работает по TCP, а не по USB |
