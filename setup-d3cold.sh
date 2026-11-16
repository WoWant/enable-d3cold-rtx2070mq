#!/usr/bin/env bash
# =============================================================================
#  setup-d3cold.sh
#
#  Заставляет дискретную NVIDIA RTX 2070 Max-Q (Turing, TU106M) уходить
#  в D3cold (полное обесточивание, 0 Вт) на гибридном ноутбуке
#  Intel UHD 630 + NVIDIA под Arch Linux + KDE Plasma Wayland.
#
#  Проверено на: MSI P65, Arch Linux (kernel 7.3.4), nvidia-open 620.70.06,
#                KDE Plasma 6.8.1 Wayland, SDDM.
#
#  Скрипт меняет драйвер GPU (nouveau -> nvidia-open) и настройки загрузки,
#  поэтому после выполнения ОБЯЗАТЕЛЬНА перезагрузка.
#
#  Запуск:  sudo bash setup-d3cold.sh
#           sudo bash setup-d3cold.sh --no-steam   # не трогать настройки Steam
# =============================================================================
set -euo pipefail

USER_NAME="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_GROUP="$(id -gn "$USER_NAME")"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SKIP_STEAM=0
for arg in "$@"; do
    case "$arg" in
        --no-steam) SKIP_STEAM=1 ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "Неизвестный аргумент: $arg" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Запустите через sudo: sudo bash $0"
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || die "Не удалось определить домашний каталог"

# ---------------------------------------------------------------------------
# Поиск GPU в /sys
# ---------------------------------------------------------------------------
find_gpu() { # $1 = vendor id (0x8086 / 0x10de)
    local d v c
    for d in /sys/bus/pci/devices/*; do
        [ -e "$d/vendor" ] || continue
        v="$(cat "$d/vendor" 2>/dev/null || true)"
        c="$(cat "$d/class" 2>/dev/null || true)"
        [ "$v" = "$1" ] || continue
        case "$c" in
            0x0300*|0x0302*) basename "$d"; return 0 ;;
        esac
    done
    return 1
}

INTEL_BDF="$(find_gpu 0x8086 || true)"
NVIDIA_BDF="$(find_gpu 0x10de || true)"

[ -n "$INTEL_BDF" ]  || die "Не найден GPU Intel. Скрипт рассчитан на гибрид Intel + NVIDIA."
[ -n "$NVIDIA_BDF" ] || die "Не найден GPU NVIDIA."

info "Intel GPU:  $INTEL_BDF"
info "NVIDIA GPU: $NVIDIA_BDF"

# Встроенный экран (eDP) должен быть на Intel, иначе modeset=0 оставит без дисплея.
EDP_ON_INTEL=0
for conn in /sys/class/drm/card*-eDP-*; do
    [ -e "$conn/status" ] || continue
    if [ "$(cat "$conn/status" 2>/dev/null)" != "connected" ]; then
        continue
    fi
    card="$(basename "$conn" | sed 's/-eDP-.*//')"
    bdf="$(basename "$(readlink -f "/sys/class/drm/$card/device" 2>/dev/null)" 2>/dev/null || true)"
    if [ "$bdf" = "$INTEL_BDF" ]; then
        EDP_ON_INTEL=1
    fi
done
[ "$EDP_ON_INTEL" -eq 1 ] || die "Встроенный экран не на Intel. Остановлено, чтобы не оставить вас без дисплея."
ok "Встроенный экран подключён к Intel — конфигурация подходит"

# BusID для xorg.conf: 0000:00:02.0 -> PCI:0:2:0 (значения в десятичном виде)
bdf_to_xorg_busid() {
    local bdf="$1"
    local bus=$((16#${bdf:5:2}))
    local dev=$((16#${bdf:8:2}))
    local fn=$((16#${bdf:11:1}))
    echo "PCI:${bus}:${dev}:${fn}"
}
INTEL_XORG_BUSID="$(bdf_to_xorg_busid "$INTEL_BDF")"

# ---------------------------------------------------------------------------
info "Шаг 1/11: обновление системы (nvidia-open должен совпасть с ядром)"
# ---------------------------------------------------------------------------
if [ -n "$(pacman -Qu 2>/dev/null || true)" ]; then
    warn "Есть непроведённые обновления — запускаю pacman -Syu"
    pacman -Syu
else
    ok "система уже обновлена"
fi

# ---------------------------------------------------------------------------
info "Шаг 2/11: установка драйвера nvidia-open и утилит"
# ---------------------------------------------------------------------------
pkgs=(nvidia-open nvidia-utils nvidia-settings nvidia-prime vulkan-intel)
if pacman -Si lib32-nvidia-utils >/dev/null 2>&1; then
    pkgs+=(lib32-nvidia-utils lib32-vulkan-intel)
else
    warn "multilib отключён: 32-битные игры/Steam не увидят NVIDIA"
fi
pacman -S --needed --noconfirm "${pkgs[@]}"
ok "установлено: ${pkgs[*]}"

if pacman -Q linux-zen >/dev/null 2>&1; then
    warn "Установлено ядро linux-zen, а nvidia-open собран только под linux."
    warn "Для linux-zen поставьте nvidia-open-dkms (плюс linux-zen-headers)."
fi

# ---------------------------------------------------------------------------
info "Шаг 3/11: удаление Vulkan-драйверов nouveau"
# ---------------------------------------------------------------------------
pacman -Rns --noconfirm vulkan-nouveau lib32-vulkan-nouveau 2>/dev/null || true
ok "vulkan-nouveau удалён (если был)"

# ---------------------------------------------------------------------------
info "Шаг 4/11: блокировка nouveau и очистка параметров ядра"
# ---------------------------------------------------------------------------
echo 'blacklist nouveau' > /etc/modprobe.d/blacklist-nouveau.conf
if compgen -G "/boot/loader/entries/*.conf" >/dev/null; then
    sed -i -E 's/ nouveau\.config=NvGspRm=[01]//g' /boot/loader/entries/*.conf
    ok "systemd-boot: NvGspRm убран из всех записей"
elif [ -f /etc/default/grub ]; then
    sed -i -E 's/ nouveau\.config=NvGspRm=[01]//g' /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    ok "GRUB: NvGspRm убран"
else
    warn "Не найден загрузчик (systemd-boot/GRUB). Уберите nouveau.config=NvGspRm=... вручную."
fi

# ---------------------------------------------------------------------------
info "Шаг 5/11: удаление старых костылей, которые мешают D3cold"
# ---------------------------------------------------------------------------
rm -f /etc/udev/rules.d/51-nvidia-usb-power.rules      # power/control=on на всю NVIDIA
rm -f /etc/udev/rules.d/71-nvidia-d3hot.rules          # d3cold_allowed=0 (запрет D3cold)
rm -f /etc/modprobe.d/blacklist-nvidia-i2c.conf
if [ -f /etc/systemd/system/nvidia-usb-power.service ]; then
    systemctl disable --now nvidia-usb-power.service 2>/dev/null || true
    rm -f /etc/systemd/system/nvidia-usb-power.service
fi
sed -i '/^POWERDEVIL_NO_DDCUTIL=/d' /etc/environment 2>/dev/null || true
ok "старые правки удалены"

# ---------------------------------------------------------------------------
info "Шаг 6/11: параметры драйвера NVIDIA"
# ---------------------------------------------------------------------------
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
# NVreg_DynamicPowerManagement=0x01 : Coarse-grained RTD3 (Turing, без VRAM self-refresh)
# NVreg_GpuInitOnProbe=0            : драйвер 620.x не инициализирует GPU на probe
#                                     и не держит ссылку питания NV_DYNAMIC_PM_COARSE
# modeset=0 fbdev=0                 : nvidia_drm не открывает GPU через NVKMS
#                                     (иначе висит ссылка + 1 MiB VRAM)
options nvidia NVreg_DynamicPowerManagement=0x01 NVreg_GpuInitOnProbe=0
options nvidia_drm modeset=0 fbdev=0

# На MSI P65 порт Type-C к NVIDIA не разведён: 01:00.3 всегда падает по тайм-ауту I2C
blacklist i2c_nvidia_gpu
blacklist ucsi_ccg
EOF
ok "/etc/modprobe.d/nvidia.conf"

# ---------------------------------------------------------------------------
info "Шаг 7/11: обход бага ядра 7.3 (nullfs) + защита от зависаний PGON"
# ---------------------------------------------------------------------------
cat > /usr/local/sbin/nvidia-rtd3-rebind <<'EOF'
#!/bin/bash
# 1) На Linux 7.3 kthread при probe работает в пустой nullfs и не может прочитать
#    /sys/bus/pci/.../config. Драйвер молча выключает RTD3. Повторный probe
#    из контекста обычного процесса (unbind/bind) читает sysfs корректно.
# 2) Удаляет неразведённые на плате функции .1 (Audio), .2 (USB xHCI), .3 (UCSI),
#    чтобы сканирование USB (adb, lsusb, fwupd) не будило карту из D3cold с
#    0 мс задержкой и не вызывало клин BIOS \_SB.PCI0.PGON (AE_AML_LOOP_TIMEOUT).
# 3) Ставит задержку автосна корневого порта PCIe 3000 мс (защита от дребезга PGOF->PGON).
set -uo pipefail
for bdf in /sys/bus/pci/drivers/nvidia/0000:*:*.*; do
    [ -e "$bdf" ] || continue
    dev=$(basename "$bdf")
    slot="${dev%.*}"
    bridge=$(basename "$(readlink -f "/sys/bus/pci/devices/$dev/..")" 2>/dev/null || true)

    echo on > "/sys/bus/pci/devices/$dev/power/control" 2>/dev/null || true

    if [ -n "$bridge" ] && [ -w "/sys/bus/pci/devices/$bridge/power/autosuspend_delay_ms" ]; then
        echo 3000 > "/sys/bus/pci/devices/$bridge/power/autosuspend_delay_ms" 2>/dev/null || true
    fi

    for fn in 1 2 3; do
        if [ -e "/sys/bus/pci/devices/${slot}.${fn}/remove" ]; then
            echo 1 > "/sys/bus/pci/devices/${slot}.${fn}/remove" 2>/dev/null || true
        fi
    done

    echo "$dev" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null || true
    echo "$dev" > /sys/bus/pci/drivers/nvidia/bind   2>/dev/null || true
    echo auto > "/sys/bus/pci/devices/$dev/power/control" 2>/dev/null || true
done
exit 0
EOF
chmod 755 /usr/local/sbin/nvidia-rtd3-rebind

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

cat > /usr/lib/systemd/system-sleep/90-nvidia-d3cold-s3 <<'EOF'
#!/bin/sh
# Безопасный переход NVIDIA D3cold <-> S3 (deep):
# будит GPU в D0 до заморозки сессий/консоли и возвращает в auto после пробуждения.
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
ok "helper + nvidia-rtd3.service + 90-nvidia-d3cold-s3"

# ---------------------------------------------------------------------------
info "Шаг 8/11: udev-правило NVIDIA (удаление .1/.2/.3 + power/control=auto)"
# ---------------------------------------------------------------------------
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
ok "/etc/udev/rules.d/80-nvidia-pm.rules"

# ---------------------------------------------------------------------------
info "Шаг 9/11: Xorg-греетер SDDM — только Intel"
# ---------------------------------------------------------------------------
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-intel-only.conf <<EOF
# Греетер SDDM (Xorg) рендерит только на Intel и не открывает /dev/nvidia*.
Section "Device"
    Identifier "intel"
    Driver "modesetting"
    BusID "$INTEL_XORG_BUSID"
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
ok "/etc/X11/xorg.conf.d/10-intel-only.conf (BusID $INTEL_XORG_BUSID)"

# ---------------------------------------------------------------------------
info "Шаг 10/11: KWin — только Intel (DRM-ограничение + EGL)"
# ---------------------------------------------------------------------------
# 10.1. Стабильные ссылки на Intel: card + render (в именах нет двоеточий!)
cat > /etc/udev/rules.d/70-intel-drm.rules <<EOF
SUBSYSTEM=="drm", KERNEL=="card*",    KERNELS=="$INTEL_BDF", SYMLINK+="dri/intel-card"
SUBSYSTEM=="drm", KERNEL=="renderD*", KERNELS=="$INTEL_BDF", SYMLINK+="dri/intel-render"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=drm --action=add 2>/dev/null || true
udevadm settle 2>/dev/null || true
ok "/etc/udev/rules.d/70-intel-drm.rules"

# 10.2. KWin управляет только Intel (DRM-карта + render-узел)
install -d -o "$USER_NAME" -g "$USER_GROUP" "$USER_HOME/.config/environment.d"
cat > "$USER_HOME/.config/environment.d/kwin-gpu.conf" <<'EOF'
KWIN_DRM_DEVICES=/dev/dri/intel-card
KWIN_RENDER_NODES=/dev/dri/intel-render
EOF
chown "$USER_NAME:" "$USER_HOME/.config/environment.d/kwin-gpu.conf"
ok "$USER_HOME/.config/environment.d/kwin-gpu.conf"

# 10.3. KWin не загружает libEGL_nvidia (это главное)
kwin_dropin_dir="$USER_HOME/.config/systemd/user/plasma-kwin_wayland.service.d"
install -d -o "$USER_NAME" -g "$USER_GROUP" "$USER_HOME/.config/systemd/user" 2>/dev/null || true
install -d -o "$USER_NAME" -g "$USER_GROUP" "$kwin_dropin_dir"
cat > "$kwin_dropin_dir/egl.conf" <<'EOF'
[Service]
# KWin рендерит только на Intel (Mesa). Без этого KWin при старте загружает
# NVIDIA-вендора EGL (libEGL_nvidia), тот открывает /dev/nvidia* и не даёт
# карте уйти в D3cold. Действует только на KWin; остальные приложения
# по-прежнему видят NVIDIA (CUDA/Vulkan/prime-run).
Environment=__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
EOF
chown "$USER_NAME:" "$kwin_dropin_dir/egl.conf"
ok "$kwin_dropin_dir/egl.conf"

# ---------------------------------------------------------------------------
info "Шаг 11/11: Steam (клиент — Intel, игры — NVIDIA)"
# ---------------------------------------------------------------------------
if [ "$SKIP_STEAM" -eq 1 ]; then
    info "пропущено по --no-steam"
else
    steam_wrap="$USER_HOME/.local/share/Steam/ubuntu12_64/steamwebhelper_sniper_wrap.sh"
    sys_desktop="/usr/share/applications/steam.desktop"
    usr_desktop="$USER_HOME/.local/share/applications/steam.desktop"

    if [ -f "$sys_desktop" ]; then
        install -d -o "$USER_NAME" -g "$USER_GROUP" "$USER_HOME/.local/share/applications"
        [ -f "$usr_desktop" ] || cp "$sys_desktop" "$usr_desktop"
        sed -i \
            -e 's/^PrefersNonDefaultGPU=.*/PrefersNonDefaultGPU=false/' \
            -e 's/^X-KDE-RunOnDiscreteGpu=.*/X-KDE-RunOnDiscreteGpu=false/' \
            "$usr_desktop"
        chown "$USER_NAME:" "$usr_desktop"
        ok "ярлык Steam: клиент больше не просит дискретную GPU"
    fi

    if [ -f "$steam_wrap" ] && ! grep -q 'D3COLD_STEAM_WEBHELPER' "$steam_wrap"; then
        block='# D3COLD_STEAM_WEBHELPER: браузер интерфейса Steam остаётся на Intel/Mesa,
# чтобы клиент Steam не открывал /dev/nvidia* и не будил дискретную карту.
export __GLX_VENDOR_LIBRARY_NAME=mesa
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/lib/pressure-vessel/overrides/share/glvnd/egl_vendor.d/50_mesa.json
export __EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES=
export VK_DRIVER_FILES=/usr/lib/pressure-vessel/overrides/share/vulkan/icd.d/intel_icd.json
export VK_ICD_FILENAMES=/usr/lib/pressure-vessel/overrides/share/vulkan/icd.d/intel_icd.json'
        tmp="${steam_wrap}.d3cold.tmp"
        awk -v block="$block" '
            BEGIN { inserted = 0 }
            /^exec \.\/steamwebhelper/ && !inserted { print block; inserted = 1 }
            { print }
        ' "$steam_wrap" > "$tmp"
        mv "$tmp" "$steam_wrap"
        chmod 755 "$steam_wrap"
        chown "$USER_NAME:" "$steam_wrap"
        ok "steamwebhelper -> Intel/Mesa (патч снимется при обновлении Steam — перезапустите скрипт)"
    elif [ ! -f "$steam_wrap" ]; then
        info "Steam не установлен — пропущено"
    else
        ok "steamwebhelper уже пропатчен"
    fi
fi

# Пере-направить ярлыки Steam на рабочем столе на пользовательский .desktop
for d in "$USER_HOME/Desktop" "$USER_HOME/Рабочий стол"; do
    if [ -L "$d/steam.desktop" ] && [ -f "$USER_HOME/.local/share/applications/steam.desktop" ]; then
        ln -sfn "$USER_HOME/.local/share/applications/steam.desktop" "$d/steam.desktop"
        ok "ярлык на рабочем столе -> пользовательский steam.desktop"
    fi
done

# ---------------------------------------------------------------------------
info "Пересборка initramfs"
# ---------------------------------------------------------------------------
mkinitcpio -P
ok "initramfs пересобран"

# ---------------------------------------------------------------------------
cat <<EOF

=============================================================================
Готово. Обязательна перезагрузка:

    sudo reboot

После перезагрузки проверяйте ТОЛЬКО так (nvidia-smi будит карту!):

    cat /sys/bus/pci/devices/$NVIDIA_BDF/power/runtime_status   # suspended
    cat /sys/bus/pci/devices/$NVIDIA_BDF/power_state            # D3cold
    sudo fuser -v /dev/nvidia*                                  # пусто

Светодиод на корпусе должен быть БЕЛЫМ (карта обесточена).

Запуск игр/вычислений на NVIDIA:

    prime-run <команда>                       # из терминала
    prime-run %command%                       # Steam: Свойства игры -> Параметры запуска

CUDA работает без prime-run (сама будит карту и отпускает её после завершения).
=============================================================================
EOF
