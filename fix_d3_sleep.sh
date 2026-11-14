#!/bin/bash
# =============================================================================
# Освободить NVIDIA от держателей (KWin + греетер Xorg), чтобы карта уходила в D3cold.
# Идемпотентный: можно запускать повторно.
# Запуск:  sudo bash ~/fix_d3_sleep.sh   (затем sudo reboot)
# =============================================================================
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите через sudo:  sudo bash $0"
    exit 1
fi
USER_NAME="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

info "1/3  Стабильная ссылка на Intel (udev)"
cat > /etc/udev/rules.d/70-intel-drm.rules <<'EOF'
SUBSYSTEM=="drm", KERNEL=="card*", KERNELS=="0000:00:02.0", SYMLINK+="dri/intel-card"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=drm --action=add 2>/dev/null || true
udevadm settle 2>/dev/null || true
if [ -L /dev/dri/intel-card ]; then
    echo "  ok: /dev/dri/intel-card -> $(readlink /dev/dri/intel-card)"
else
    echo "  ВНИМАНИЕ: ссылка появится после перезагрузки (правило на месте)."
fi

info "2/3  KWin — только Intel"
mkdir -p "$USER_HOME/.config/environment.d"
cat > "$USER_HOME/.config/environment.d/kwin-gpu.conf" <<'EOF'
KWIN_DRM_DEVICES=/dev/dri/intel-card
EOF
chown "$USER_NAME:" "$USER_HOME/.config/environment.d/kwin-gpu.conf"
echo "  ok: $USER_HOME/.config/environment.d/kwin-gpu.conf"

info "3/3  Греетер Xorg — только Intel (не открывать NVIDIA)"
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-intel-only.conf <<'EOF'
Section "Device"
    Identifier "intel"
    Driver "modesetting"
    BusID "PCI:0:2:0"
EndSection

Section "Screen"
    Identifier "intel-screen"
    Device "intel"
EndSection

Section "ServerLayout"
    Identifier "layout"
    Screen 0 "intel-screen" 0 0
    Option "AutoAddGPU" "false"
EndSection
EOF
echo "  ok: /etc/X11/xorg.conf.d/10-intel-only.conf"

echo
echo "Готово. Перезагрузитесь:  sudo reboot"
echo
echo "После перезагрузки проверьте:"
echo "  sudo fuser -v /dev/nvidia*               # ожидаем ПУСТО"
echo "  cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status   # suspended"
echo "  # светодиод корпуса должен стать белым"
echo
echo "Если экран входа не загрузится — откат:"
echo "  sudo rm /etc/X11/xorg.conf.d/10-intel-only.conf && sudo reboot"
