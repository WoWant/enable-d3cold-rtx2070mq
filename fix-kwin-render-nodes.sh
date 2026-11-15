#!/usr/bin/env bash
# =============================================================================
# Hotfix для KWin 6.8.2: GpuManager сканирует ВСЕ render-узлы, находит
# renderD129 (NVIDIA) и открывает его — из-за этого KWin держит /dev/nvidia*
# и карта не уходит в D3cold.
#
# Решение: KWIN_RENDER_NODES — разрешить KWin только Intel render-узел.
#
# Запуск:  sudo bash fix-kwin-render-nodes.sh
# Затем:   sudo reboot
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo: sudo bash $0"; exit 1; }

USER_NAME="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_GROUP="$(id -gn "$USER_NAME")"

# Ищем Intel GPU (vendor 0x8086, класс дисплея)
INTEL_BDF=""
for d in /sys/bus/pci/devices/*; do
    [ -e "$d/vendor" ] || continue
    [ "$(cat "$d/vendor" 2>/dev/null)" = "0x8086" ] || continue
    case "$(cat "$d/class" 2>/dev/null)" in
        0x0300*|0x0302*) INTEL_BDF="$(basename "$d")"; break ;;
    esac
done
[ -n "$INTEL_BDF" ] || { echo "Не найден GPU Intel"; exit 1; }

echo "==> Intel GPU: $INTEL_BDF"

echo "==> 1/2  udev: стабильные ссылки на Intel (card + render)"
cat > /etc/udev/rules.d/70-intel-drm.rules <<EOF
SUBSYSTEM=="drm", KERNEL=="card*",    KERNELS=="$INTEL_BDF", SYMLINK+="dri/intel-card"
SUBSYSTEM=="drm", KERNEL=="renderD*", KERNELS=="$INTEL_BDF", SYMLINK+="dri/intel-render"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=drm --action=add 2>/dev/null || true
udevadm settle 2>/dev/null || true

echo "--> /dev/dri/intel-card:   $(readlink -f /dev/dri/intel-card 2>/dev/null || echo 'появится после ребута')"
echo "--> /dev/dri/intel-render: $(readlink -f /dev/dri/intel-render 2>/dev/null || echo 'появится после ребута')"

echo "==> 2/2  KWin: только Intel DRM + render-узел"
install -d -o "$USER_NAME" -g "$USER_GROUP" "$USER_HOME/.config/environment.d"
cat > "$USER_HOME/.config/environment.d/kwin-gpu.conf" <<'EOF'
KWIN_DRM_DEVICES=/dev/dri/intel-card
KWIN_RENDER_NODES=/dev/dri/intel-render
EOF
chown "$USER_NAME:" "$USER_HOME/.config/environment.d/kwin-gpu.conf"

cat <<'EOF'

Готово. Нужна перезагрузка:

    sudo reboot

После перезагрузки (nvidia-smi не запускать — он будит карту):

    sudo fuser -v /dev/nvidia*                                   # пусто
    cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status   # suspended
    cat /sys/bus/pci/devices/0000:01:00.0/power_state            # D3cold
EOF
