#!/bin/bash
# =============================================================================
# Включение D3cold (0 Вт, белый индикатор) для NVIDIA Turing (Coarse RTD3)
# на драйвере 620.x и ядре Linux 7.3:
#   1) NVreg_GpuInitOnProbe=0 — не держать карту инициализированной с момента probe
#   2) NVreg_DynamicPowerManagement=0x01 — Coarse-grained RTD3
#   3) nvidia_drm modeset=0 fbdev=0 — не держать открытым NVKMS (1 MiB VRAM)
#   4) Re-probe в контексте процесса (обход бага nullfs ядра 7.3) + power/control=auto
#
# Запуск:  sudo bash ~/enable_d3cold.sh
# =============================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите через sudo:  sudo bash $0"
    exit 1
fi

echo "==> 1/4  Запись параметров в /etc/modprobe.d/nvidia.conf"
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia NVreg_DynamicPowerManagement=0x01 NVreg_GpuInitOnProbe=0
options nvidia_drm modeset=0 fbdev=0
EOF

echo "==> 2/4  Перезагрузка модулей NVIDIA с новыми параметрами"
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia
modprobe nvidia

echo "==> 3/4  Re-probe в контексте процесса и включение auto"
/usr/local/sbin/nvidia-rtd3-rebind
echo auto > /sys/bus/pci/devices/0000:01:00.0/power/control

echo "==> 4/4  Ожидание 15 секунд (не запускайте nvidia-smi!)..."
sleep 15

echo "=== Проверка параметров ==="
echo "NVreg_GpuInitOnProbe = $(cat /sys/module/nvidia/parameters/NVreg_GpuInitOnProbe)"
echo "NVreg_DynamicPowerManagement = $(cat /sys/module/nvidia/parameters/NVreg_DynamicPowerManagement)"
echo "nvidia_drm modeset = $(cat /sys/module/nvidia_drm/parameters/modeset)"

echo "=== Статус PCI-устройств 01:00.* ==="
for d in /sys/bus/pci/devices/0000:01:00.*; do
    echo "$d: control=$(cat "$d/power/control") status=$(cat "$d/power/runtime_status") state=$(cat "$d/power_state" 2>/dev/null || echo ?)"
done

echo "=== Статус NVIDIA RTD3 ==="
cat /proc/driver/nvidia/gpus/0000:01:00.0/power
