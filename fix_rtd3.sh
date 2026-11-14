#!/bin/bash
# =============================================================================
# Включение RTD3 (засыпания dGPU) для NVIDIA Turing + Linux 7.3.
#
# Две проблемы разом:
#  1) Для Turing RTD3 отключён по умолчанию -> нужен NVreg_DynamicPowerManagement=0x01
#  2) Баг Linux 7.3 (kthread в nullfs): драйвер не может прочитать sysfs при
#     автозагрузке и молча выключает RTD3. Обход — re-probe карты в контексте
#     процесса (unbind/bind) до старта дисплейного менеджера.
#
# Запуск:  sudo bash ~/fix_rtd3.sh
# =============================================================================
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите через sudo:  sudo bash $0"
    exit 1
fi

info "1/3  Параметр NVreg_DynamicPowerManagement=0x01 (Turing)"
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia NVreg_DynamicPowerManagement=0x01
options nvidia_drm modeset=1
EOF
echo "    записано в /etc/modprobe.d/nvidia.conf"

info "2/3  Helper: re-probe GPU (обход бага nullfs)"
cat > /usr/local/sbin/nvidia-rtd3-rebind <<'EOF'
#!/bin/bash
# Re-probe NVIDIA GPU в контексте процесса, чтобы драйвер включил RTD3.
# Workaround бага Linux 7.3: kthread не может прочитать /sys/.../config.
set -uo pipefail
for bdf in /sys/bus/pci/drivers/nvidia/0000:*:*.*; do
    [ -e "$bdf" ] || continue
    dev=$(basename "$bdf")
    echo "$dev" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null || true
    echo "$dev" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || true
done
exit 0
EOF
chmod +x /usr/local/sbin/nvidia-rtd3-rebind
echo "    /usr/local/sbin/nvidia-rtd3-rebind"

info "3/3  systemd-сервис (re-probe до старта sddm)"
cat > /etc/systemd/system/nvidia-rtd3.service <<'EOF'
[Unit]
Description=Re-probe NVIDIA GPU to enable runtime D3 (RTD3)
After=multi-user.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-rtd3-rebind
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable nvidia-rtd3.service >/dev/null 2>&1 || true
echo "    сервис включён"

echo
echo "Готово. Перезагрузитесь:  sudo reboot"
echo
echo "После перезагрузки проверьте:"
echo "  cat /proc/driver/nvidia/gpus/0000:01:00.0/power"
echo "  Должно быть:  Runtime D3 status: Enabled (coarse-grained)"
echo "  cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status"
echo "  Должно стать: suspended (когда карта не используется)"
