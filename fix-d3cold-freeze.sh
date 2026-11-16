#!/usr/bin/env bash
# =============================================================================
#  fix-d3cold-freeze.sh
#
#  Устраняет намертво зависающий ноутбук (жёлтый светодиод, вентиляторы на
#  максимуме, в логе:
#    ACPI Error: Aborting method \_SB.PCI0.PGON (AE_AML_LOOP_TIMEOUT)
#    ACPI Error: Aborting method \_SB.PCI0.PEG0.PG00._ON (AE_AML_LOOP_TIMEOUT)
#    nvidia 0000:01:00.0: not ready ... after resume; waiting
#  ) при работе фоновых утилит (adb, lsusb, fwupd) и при уходе в S3 (deep).
#
#  Причина:
#    1) В чипе RTX 2070 Max-Q (TU106M) есть неразведённые на плате MSI P65
#       функции 01:00.2 (USB xHCI, шины usb3/usb4), 01:00.3 (UCSI Type-C) и
#       01:00.1 (HDMI Audio, бесполезный при nvidia_drm modeset=0).
#    2) Любое сканирование USB (например, старт adb-сервера в фоне) будит
#       usb3/usb4 -> 01:00.2 -> 01:00.0 из D3cold в обход /dev/nvidia*
#       с задержкой автосна 0 мс. Драйвер xhci_hcd падает с
#       "xHC error in resume, USBSTS 0x401, Reinit", вызывая мгновенный
#       дребезг питания PGOF -> PGON на корневом порту PCIe 00:01.0 (PEG0).
#       Метод BIOS \_SB.PCI0.PGON зацикливается на 30 с (AE_AML_LOOP_TIMEOUT),
#       оставляя GPU с включённым питанием (жёлтый LED), но мёртвым на шине.
#    3) Та же гонка происходит при входе в S3 (deep), когда ядро будит
#       01:00.2 / 01:00.0 из D3cold уже после заморозки процессов и консоли.
#
#  Решение:
#    1) Удалять 01:00.1, 01:00.2, 01:00.3 через udev (официальная рекомендация
#       NVIDIA из README §21H для Turing) + заблокировать i2c_nvidia_gpu/ucsi_ccg.
#    2) Увеличить autosuspend_delay_ms корневого порта PCIe 00:01.0 с 100 мс
#       до 3000 мс (защита от дребезга PGOF -> PGON).
#    3) Перед входом в S3 (deep) будить GPU в D0 заранее в обычном контексте
#       (/usr/lib/systemd/system-sleep/90-nvidia-d3cold-s3), а после выхода
#       возвращать power/control=auto.
#
#  Запуск:
#    sudo bash ~/Projects/enable_d3cold_rtx2070mq/fix-d3cold-freeze.sh
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo: sudo bash $0"; exit 1; }

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }

info "1/5  Обновление /etc/modprobe.d/nvidia.conf (блокировка i2c_nvidia_gpu и ucsi_ccg)"
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
# NVreg_DynamicPowerManagement=0x01 : Coarse-grained RTD3 (Turing, без VRAM self-refresh)
# NVreg_GpuInitOnProbe=0            : драйвер 620.x не инициализирует GPU на probe
#                                     и не держит ссылку питания NV_DYNAMIC_PM_COARSE
# modeset=0 fbdev=0                 : nvidia_drm не открывает GPU через NVKMS
options nvidia NVreg_DynamicPowerManagement=0x01 NVreg_GpuInitOnProbe=0
options nvidia_drm modeset=0 fbdev=0

# На MSI P65 порт Type-C к NVIDIA не разведён: 01:00.3 всегда падает по тайм-ауту I2C
blacklist i2c_nvidia_gpu
blacklist ucsi_ccg
EOF
ok "/etc/modprobe.d/nvidia.conf"

info "2/5  Обновление /etc/udev/rules.d/80-nvidia-pm.rules (удаление 01:00.1 / .2 / .3)"
cat > /etc/udev/rules.d/80-nvidia-pm.rules <<'EOF'
# Remove unused NVIDIA USB xHCI Host Controller (01:00.2) — prevents usb3/usb4
# from waking the GPU out of D3cold on USB scans (adb, lsusb, fwupd) and
# triggering \_SB.PCI0.PGON AE_AML_LOOP_TIMEOUT freezes.
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", ATTR{remove}="1"

# Remove unused NVIDIA USB Type-C UCSI Controller (01:00.3)
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", ATTR{remove}="1"

# Remove unused NVIDIA Audio device (01:00.1, unusable with nvidia_drm modeset=0)
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ATTR{remove}="1"

# Enable runtime PM for NVIDIA VGA/3D controller devices on driver bind
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"

# Disable runtime PM for NVIDIA VGA/3D controller devices on driver unbind
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
EOF
udevadm control --reload
ok "/etc/udev/rules.d/80-nvidia-pm.rules"

info "3/5  Обновление /usr/local/sbin/nvidia-rtd3-rebind"
cat > /usr/local/sbin/nvidia-rtd3-rebind <<'EOF'
#!/bin/bash
set -uo pipefail

for bdf in /sys/bus/pci/drivers/nvidia/0000:*:*.*; do
    [ -e "$bdf" ] || continue
    dev=$(basename "$bdf")
    slot="${dev%.*}"
    bridge=$(basename "$(readlink -f "/sys/bus/pci/devices/$dev/..")" 2>/dev/null || true)

    # 1. Будим GPU в D0 перед операциями на шине
    echo on > "/sys/bus/pci/devices/$dev/power/control" 2>/dev/null || true

    # 2. Защита от дребезга PGOF -> PGON на корневом порту PCIe (3000 мс вместо 100 мс)
    if [ -n "$bridge" ] && [ -w "/sys/bus/pci/devices/$bridge/power/autosuspend_delay_ms" ]; then
        echo 3000 > "/sys/bus/pci/devices/$bridge/power/autosuspend_delay_ms" 2>/dev/null || true
    fi

    # 3. Удаляем неиспользуемые функции .1 (Audio), .2 (USB xHCI), .3 (UCSI),
    #    если они появились в initramfs до срабатывания udev-правил
    for fn in 1 2 3; do
        if [ -e "/sys/bus/pci/devices/${slot}.${fn}/remove" ]; then
            echo 1 > "/sys/bus/pci/devices/${slot}.${fn}/remove" 2>/dev/null || true
        fi
    done

    # 4. Re-probe драйвера nvidia из контекста процесса (обход бага nullfs ядра 7.3)
    echo "$dev" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null || true
    echo "$dev" > /sys/bus/pci/drivers/nvidia/bind   2>/dev/null || true
    echo auto > "/sys/bus/pci/devices/$dev/power/control" 2>/dev/null || true
done
exit 0
EOF
chmod 755 /usr/local/sbin/nvidia-rtd3-rebind
ok "/usr/local/sbin/nvidia-rtd3-rebind"

info "4/5  Добавление sleep-хука /usr/lib/systemd/system-sleep/90-nvidia-d3cold-s3"
cat > /usr/lib/systemd/system-sleep/90-nvidia-d3cold-s3 <<'EOF'
#!/bin/sh
# Безопасный переход NVIDIA D3cold <-> S3 (deep):
# - pre:  будит GPU в D0 в обычном контексте процесса до заморозки сессий
#         и остановки консоли/EC, чтобы ядро не вызывало PGON внутри dpm_suspend.
# - post: удаляет .1/.2/.3 (если BIOS переинициализировал их после S3),
#         выставляет задержку моста 3000 мс и возвращает GPU в auto (D3cold).

case "${2:-}" in
    suspend|hibernate|suspend-then-hibernate|hybrid-sleep) ;;
    *) exit 0 ;;
esac

for bdf in /sys/bus/pci/drivers/nvidia/0000:*:*.*; do
    [ -e "$bdf" ] || continue
    dev=$(basename "$bdf")
    slot="${dev%.*}"
    bridge=$(basename "$(readlink -f "/sys/bus/pci/devices/$dev/..")" 2>/dev/null || true)

    case "$1" in
        pre)
            if [ -w "/sys/bus/pci/devices/$dev/power/control" ]; then
                echo on > "/sys/bus/pci/devices/$dev/power/control" 2>/dev/null || true
                sleep 1
            fi
            ;;
        post)
            if [ -n "$bridge" ] && [ -w "/sys/bus/pci/devices/$bridge/power/autosuspend_delay_ms" ]; then
                echo 3000 > "/sys/bus/pci/devices/$bridge/power/autosuspend_delay_ms" 2>/dev/null || true
            fi
            for fn in 1 2 3; do
                if [ -e "/sys/bus/pci/devices/${slot}.${fn}/remove" ]; then
                    echo 1 > "/sys/bus/pci/devices/${slot}.${fn}/remove" 2>/dev/null || true
                fi
            done
            if [ -w "/sys/bus/pci/devices/$dev/power/control" ]; then
                echo auto > "/sys/bus/pci/devices/$dev/power/control" 2>/dev/null || true
            fi
            ;;
    esac
done
exit 0
EOF
chmod 755 /usr/lib/systemd/system-sleep/90-nvidia-d3cold-s3
ok "/usr/lib/systemd/system-sleep/90-nvidia-d3cold-s3"

info "5/5  Применение в текущей сессии и пересборка initramfs"
echo 3000 > /sys/bus/pci/devices/0000:00:01.0/power/autosuspend_delay_ms 2>/dev/null || true
echo on > /sys/bus/pci/devices/0000:01:00.0/power/control 2>/dev/null || true
sleep 1
for fn in 1 2 3; do
    if [ -e "/sys/bus/pci/devices/0000:01:00.${fn}/remove" ]; then
        echo 1 > "/sys/bus/pci/devices/0000:01:00.${fn}/remove" 2>/dev/null || true
    fi
done
modprobe -r ucsi_ccg i2c_nvidia_gpu 2>/dev/null || true
echo auto > /sys/bus/pci/devices/0000:01:00.0/power/control 2>/dev/null || true

mkinitcpio -P
ok "initramfs пересобран, неиспользуемые функции 01:00.1/.2/.3 отключены"

cat <<'EOF'

=============================================================================
Готово! Изменения уже применены в текущей сессии (и сохранены для следующих
загрузок).

Проверка через 15 секунд:
    lspci -s 01:00                                              # только 01:00.0
    cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status  # suspended
    cat /sys/bus/pci/devices/0000:01:00.0/power_state           # D3cold
=============================================================================
EOF
