# NVIDIA RTX 2070 Max-Q: засыпание в D3cold (0 Вт)

Гибридный ноутбук **MSI P65** (Intel UHD 630 + NVIDIA RTX 2070 Max-Q, Turing TU106M)
под **Arch Linux + KDE Plasma Wayland + SDDM**.

Скрипт `setup-d3cold.sh` приводит систему к состоянию, в котором:

- дискретная NVIDIA **уходит в D3cold** (полное обесточивание, ~0 Вт),
  когда не используется;
- **светодиод на корпусе становится белым** (оранжевый = карта под питанием);
- игры/вычисления на NVIDIA запускаются по требованию и после завершения
  карта снова засыпает;
- рабочий стол, KWin и экран входа SDDM работают на Intel и **не будят**
  дискретную карту.

---

## 1. Какие симптомы это лечит

1. **Зависания KWin** («The main thread was hanging temporarily!», замирание
   мыши/интерфейса на 1–2 секунды, особенно при видео и переключении окон).
   Причина: nouveau на Turing перезагружает GSP-прошивку при каждом
   пробуждении карты (~0.5–1.5 с), а KWin в этот момент обращается к dGPU.
2. **Дискретная карта не спит** под проприетарным драйвером: ноутбук на
   батарее живёт меньше, светодиод постоянно оранжевый.

## 2. Почему это происходило

### 2.1. Зависания (nouveau)

KWin при композитинге синхронизирует кадры с dGPU (`drmSyncobjEventfd`).
Если карта в D3cold, nouveau поднимает её: переучивание PCIe + перезагрузка
GSP ≈ 1.5 с (или ≈0.5 с из D3hot). Главный поток KWin в это время стоит.

### 2.2. Карта не засыпала (nvidia-open)

Сложились четыре независимые причины:

| # | Причина | Решение |
|---|---------|---------|
| 1 | Для **Turing** RTD3 выключен по умолчанию (в отличие от Ampere/Ada) | `NVreg_DynamicPowerManagement=0x01` |
| 2 | Баг **ядра 7.3** (`kthread` в `nullfs`): драйвер при probe не читает `/sys/.../config` и молча выключает RTD3 | re-probe GPU из контекста процесса (unbind/bind) |
| 3 | Драйвер **620.x**: `NVreg_GpuInitOnProbe=2` (по умолчанию) инициализирует GPU на probe и **никогда не отпускает** ссылку `NV_DYNAMIC_PM_COARSE` | `NVreg_GpuInitOnProbe=0` |
| 4 | `nvidia_drm modeset=1` через NVKMS держит GPU открытым (+1 MiB VRAM) | `nvidia_drm modeset=0 fbdev=0` |
| 5 | Держатели `/dev/nvidia*` (Xorg-греетер SDDM, KWin) не дают `usage_count` стать 0 | Xorg → только Intel; KWin → только Mesa/Intel |

Любая одна из причин 1–5 блокирует D3cold. Нужны все сразу.

## 3. Итоговая рабочая конфигурация

```
/etc/modprobe.d/blacklist-nouveau.conf   blacklist nouveau
/etc/modprobe.d/nvidia.conf              RTD3 + GpuInitOnProbe + modeset=0 fbdev=0
/usr/local/sbin/nvidia-rtd3-rebind       re-probe GPU (обход nullfs)
/etc/systemd/system/nvidia-rtd3.service  запуск re-probe до display-manager
/etc/udev/rules.d/80-nvidia-pm.rules     power/control=auto при bind
/etc/udev/rules.d/70-intel-drm.rules     стабильная ссылка /dev/dri/intel-card
/etc/X11/xorg.conf.d/10-intel-only.conf  Xorg-греетер только на Intel
~/.config/environment.d/kwin-gpu.conf    KWIN_DRM_DEVICES -> только Intel
~/.config/systemd/user/plasma-kwin_wayland.service.d/egl.conf
                                         KWin не грузит libEGL_nvidia
```

Плюс: драйвер `nvidia-open`, удалён `vulkan-nouveau`, из параметров ядра убран
`nouveau.config=NvGspRm=...`, удалены старые костыли (`51-nvidia-usb-power.rules`,
`71-nvidia-d3hot.rules`, `nvidia-usb-power.service`, `POWERDEVIL_NO_DDCUTIL`).

## 4. Требования

- Arch Linux (проверено на ядре **7.3.4**; на 7.2.x бага nullfs нет, но
  остальные пункты актуальны).
- Гибрид **Intel + NVIDIA Turing** (RTX 20xx Mobile). Для Ampere/Ada
  пункт `NVreg_DynamicPowerManagement` не нужен (там RTD3 по умолчанию).
- **KDE Plasma 6 Wayland** + SDDM (Xorg-греетер).
- Встроенный экран подключён к Intel (в этой модели — да, eDP на i915).
- Свободный доступ к `sudo`, интернет для `pacman`.

## 5. Быстрый старт

```bash
cd ~/Projects/enable_d3cold_rtx2070mq
sudo bash setup-d3cold.sh
sudo reboot
```

Флаг `--no-steam` пропускает настройку Steam.

> Скрипт меняет драйвер GPU и initramfs. После выполнения **обязательна
> перезагрузка**. Если что-то пойдёт не так — см. раздел «Откат».

## 6. Что делает скрипт (и как повторить вручную)

Скрипт идемпотентен: повторный запуск безопасен.

### Шаг 1. Обновление системы

```bash
sudo pacman -Syu
```

Зачем: `nvidia-open` собирается под текущую версию пакета `linux`.
Если ядро отстало, модуль не загрузится (именно так случилось в первый раз).

### Шаг 2. Установка драйвера

```bash
sudo pacman -S --needed nvidia-open nvidia-utils nvidia-settings nvidia-prime \
    vulkan-intel lib32-vulkan-intel lib32-nvidia-utils
```

- `nvidia-open` — открытые модули NVIDIA (Turing поддерживается);
- `nvidia-prime` — команда `prime-run`;
- `vulkan-intel` — Vulkan на Intel (нужен, чтобы клиент Steam не выбирал NVIDIA);
- `lib32-*` — для 32-битных игр (только при включённом multilib).

### Шаг 3. Удалить Vulkan nouveau

```bash
sudo pacman -Rns vulkan-nouveau lib32-vulkan-nouveau
```

### Шаг 4. Заблокировать nouveau и убрать его параметр из ядра

```bash
echo 'blacklist nouveau' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
sudo sed -i -E 's/ nouveau\.config=NvGspRm=[01]//g' /boot/loader/entries/*.conf
```

Для GRUB — то же в `/etc/default/grub`, затем `sudo grub-mkconfig -o /boot/grub/grub.cfg`.

### Шаг 5. Удалить старые костыли

```bash
sudo rm -f /etc/udev/rules.d/51-nvidia-usb-power.rules
sudo rm -f /etc/udev/rules.d/71-nvidia-d3hot.rules
sudo rm -f /etc/modprobe.d/blacklist-nvidia-i2c.conf
sudo systemctl disable --now nvidia-usb-power.service 2>/dev/null
sudo rm -f /etc/systemd/system/nvidia-usb-power.service
sudo sed -i '/^POWERDEVIL_NO_DDCUTIL=/d' /etc/environment
```

Почему: `51-nvidia-usb-power.rules` ставит `power/control=on` на всю NVIDIA,
а `71-nvidia-d3hot.rules` (`d3cold_allowed=0`) **запрещает** D3cold. Остальное —
неудачные попытки, которые не влияют на результат.

### Шаг 6. Параметры драйвера

```bash
sudo tee /etc/modprobe.d/nvidia.conf >/dev/null <<'EOF'
options nvidia NVreg_DynamicPowerManagement=0x01 NVreg_GpuInitOnProbe=0
options nvidia_drm modeset=0 fbdev=0
EOF
```

- `NVreg_DynamicPowerManagement=0x01` — coarse-grained RTD3 для Turing.
- `NVreg_GpuInitOnProbe=0` — драйвер не инициализирует GPU на probe и не
  держит ссылку питания.
- `modeset=0 fbdev=0` — `nvidia_drm` не открывает GPU через NVKMS.

### Шаг 7. Обход бага ядра 7.3 (re-probe)

```bash
sudo tee /usr/local/sbin/nvidia-rtd3-rebind >/dev/null <<'EOF'
#!/bin/bash
set -uo pipefail
for bdf in /sys/bus/pci/drivers/nvidia/0000:*:*.*; do
    [ -e "$bdf" ] || continue
    dev=$(basename "$bdf")
    echo "$dev" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null || true
    echo "$dev" > /sys/bus/pci/drivers/nvidia/bind   2>/dev/null || true
    echo auto > "/sys/bus/pci/devices/$dev/power/control" 2>/dev/null || true
done
exit 0
EOF
sudo chmod 755 /usr/local/sbin/nvidia-rtd3-rebind

sudo tee /etc/systemd/system/nvidia-rtd3.service >/dev/null <<'EOF'
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
sudo systemctl enable nvidia-rtd3.service
```

Зачем: на ядре 7.3 модуль загружается из kthread, который не видит sysfs.
Повторный probe из обычного процесса читает sysfs корректно и включает RTD3.

### Шаг 8. Разрешить runtime PM в udev

```bash
sudo tee /etc/udev/rules.d/80-nvidia-pm.rules >/dev/null <<'EOF'
ACTION=="bind",   SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind",   SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
EOF
```

### Шаг 9. Xorg-греетер SDDM — только Intel

```bash
sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/10-intel-only.conf >/dev/null <<'EOF'
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
```

`BusID` соответствует вашему Intel GPU (`0000:00:02.0` → `PCI:0:2:0`).
Скрипт вычисляет его автоматически.

### Шаг 10. KWin — только Intel

Сначала стабильная ссылка на Intel (в имени нет двоеточий — это важно для
следующего пункта):

```bash
sudo tee /etc/udev/rules.d/70-intel-drm.rules >/dev/null <<'EOF'
SUBSYSTEM=="drm", KERNEL=="card*", KERNELS=="0000:00:02.0", SYMLINK+="dri/intel-card"
EOF
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=drm --action=add
sudo udevadm settle
ls -l /dev/dri/intel-card          # -> card1 (Intel)
```

Ограничение KWin на Intel-карту:

```bash
mkdir -p ~/.config/environment.d
cat > ~/.config/environment.d/kwin-gpu.conf <<'EOF'
KWIN_DRM_DEVICES=/dev/dri/intel-card
EOF
```

И главное — KWin не должен грузить NVIDIA-вендора EGL:

```bash
mkdir -p ~/.config/systemd/user/plasma-kwin_wayland.service.d
cat > ~/.config/systemd/user/plasma-kwin_wayland.service.d/egl.conf <<'EOF'
[Service]
Environment=__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
EOF
```

Зачем: `KWIN_DRM_DEVICES` ограничивает DRM-бэкенд, но само по себе не мешает
KWin загрузить `libEGL_nvidia`, который открывает `/dev/nvidia*` и держит
карту в D0. Именно EGL-drop-in решает эту проблему. Ограничение по DRM
оставлено как дополнительная страховка.

### Шаг 11. Steam (опционально)

Клиент Steam (`steamwebhelper`) не должен сидеть на dGPU:

```bash
mkdir -p ~/.local/share/applications
cp /usr/share/applications/steam.desktop ~/.local/share/applications/steam.desktop
sed -i 's/^PrefersNonDefaultGPU=.*/PrefersNonDefaultGPU=false/; s/^X-KDE-RunOnDiscreteGpu=.*/X-KDE-RunOnDiscreteGpu=false/' \
    ~/.local/share/applications/steam.desktop
```

И в `~/.local/share/Steam/ubuntu12_64/steamwebhelper_sniper_wrap.sh` **перед**
строкой `exec ./steamwebhelper ...` добавить:

```bash
export __GLX_VENDOR_LIBRARY_NAME=mesa
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/lib/pressure-vessel/overrides/share/glvnd/egl_vendor.d/50_mesa.json
export __EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES=
export VK_DRIVER_FILES=/usr/lib/pressure-vessel/overrides/share/vulkan/icd.d/intel_icd.json
export VK_ICD_FILENAMES=/usr/lib/pressure-vessel/overrides/share/vulkan/icd.d/intel_icd.json
```

### Шаг 12. Пересобрать initramfs

```bash
sudo mkinitcpio -P
```

Нужно, чтобы `blacklist nouveau` попал в initramfs.

### Шаг 13. Перезагрузка

```bash
sudo reboot
```

## 7. Проверка

> **Важно:** `nvidia-smi` сам будит карту. Для проверки сна используйте
> только sysfs.

```bash
# 1. PCI-состояние карты (должно быть suspended / D3cold)
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status   # suspended
cat /sys/bus/pci/devices/0000:01:00.0/power_state            # D3cold

# 2. Все функции карты (видео, аудио, USB, UCSI) спят
for d in /sys/bus/pci/devices/0000:01:00.*; do
    echo "$d: $(cat $d/power/runtime_status) / $(cat $d/power_state)"
done

# 3. Никто не держит /dev/nvidia* (должно быть пусто)
sudo fuser -v /dev/nvidia*

# 4. Светодиод на корпусе — белый
```

Если карта просыпалась, RTD3 можно посмотреть так (при активной карте):

```bash
cat /proc/driver/nvidia/gpus/0000:01:00.0/power
# Runtime D3 status: Enabled (coarse-grained)
```

Пока карта в D3cold, часть полей этого файла показывает `?` — это нормально
(драйвер не может опросить обесточенный чип).

## 8. Игры и вычисления на NVIDIA

```bash
# Из терминала
prime-run glxinfo | grep "OpenGL renderer"
prime-run blender

# Steam: Свойства игры → Общие → Параметры запуска
prime-run %command%
```

- `CUDA`, `OpenCL`, `Vulkan`-вычисления работают напрямую: они сами будят
  карту через `/dev/nvidia*` и отпускают её после завершения процесса.
- Пока программа работает, светодиод оранжевый, `runtime_status` = `active`.
  Через ~10–15 секунд после выхода — снова `suspended` / `D3cold`.

## 9. Откат

Полный откат на nouveau (вернутся зависания, но система будет рабочей):

```bash
sudo rm -f /etc/modprobe.d/nvidia.conf /etc/modprobe.d/blacklist-nouveau.conf
sudo rm -f /etc/udev/rules.d/80-nvidia-pm.rules
sudo rm -f /etc/systemd/system/nvidia-rtd3.service
sudo rm -f /usr/local/sbin/nvidia-rtd3-rebind
sudo rm -f /etc/X11/xorg.conf.d/10-intel-only.conf
rm -f ~/.config/systemd/user/plasma-kwin_wayland.service.d/egl.conf
sudo pacman -S --needed vulkan-nouveau lib32-vulkan-nouveau
sudo mkinitcpio -P
sudo reboot
```

Если после настройки не поднимается экран входа — удалите `10-intel-only.conf`
и перезагрузитесь:

```bash
sudo rm /etc/X11/xorg.conf.d/10-intel-only.conf
sudo reboot
```

## 10. Важные оговорки

1. **Внешние мониторы на портах NVIDIA** (HDMI/DP на самой карте) не заработают
   при `nvidia_drm modeset=0`. Если они нужны — поставьте `modeset=1`
   (и, скорее всего, карта перестанет уходить в D3cold, пока монитор подключён).
2. **`linux-zen`**: `nvidia-open` собран только под ядро `linux`. Для `linux-zen`
   установите `nvidia-open-dkms` + `linux-zen-headers` (иначе в zen не будет
   драйвера NVIDIA, а nouveau уже заблокирован).
3. **Обновление Steam** перезаписывает `steamwebhelper_sniper_wrap.sh`. Если
   клиент Steam снова начал будить карту — повторно запустите скрипт.
4. **Батарея**: на момент настройки её здоровье было ~63%
   (`charge_full` 3314 из `charge_full_design` 5280 мАч), `cycle_count = 0`.
   Даже при идеальном сне карты автономность ограничена износом аккумулятора.
5. **`nvidia-smi` будит карту** — не используйте его для проверки сна.
6. `pcie_aspm=off` и `mem_sleep_default=s2idle` в параметрах ядра — ваши
   прежние настройки, к этой задаче отношения не имеют; скрипт их не трогает.

## 11. Что пробовали и отбросили

| Попытка | Результат |
|---------|-----------|
| `nouveau.config=NvGspRm=0` | Хуже: без GSP у nouveau нет PMU-прошивки, посыпались `job timeout` |
| `nouveau.runpm=0` | Зависаний нет, но карта всегда в D0 (батарея ~2 ч) |
| Полностью заблокировать nouveau | Карта не используется вообще (не подходит) |
| `d3cold_allowed=0` на nouveau | Убрало только переучивание PCIe; GSP-переинициализация (~0.5 с) осталась. А на nvidia **запрещает** D3cold |
| `POWERDEVIL_NO_DDCUTIL=1` | На причину не влияет |
| `KWIN_DRM_DEVICES` с `by-path` | Сломало экран: KWin режет значение по `:`, а в `pci-0000:00:02.0-card` есть двоеточия |
| `KWIN_DRM_DEVICES` (правильный путь) | Само по себе не помогло: KWin всё равно грузил `libEGL_nvidia`. Решил EGL-drop-in; ограничение по DRM оставлено как страховка |
| `libva-nvidia-driver` | Бесполезен с nouveau (это драйвер для проприетарного NVIDIA) |
| `nvidia_drm modeset=1` | Держит GPU через NVKMS (+1 MiB VRAM) — блокирует D3 |
| `NVreg_DynamicPowerManagement=0x02` | На Turing `Not supported`; рабочий вариант — `0x01` |

Из этого в итоговый скрипт **не вошло** ничего, кроме проверенных шагов.

## 12. Файлы каталога

| Файл | Назначение |
|------|------------|
| `setup-d3cold.sh` | Единый скрипт настройки (используйте его) |
| `fix_rtd3.sh` | Промежуточный шаг: RTD3 + re-probe (вобрано в `setup-d3cold.sh`) |
| `fix_d3_sleep.sh` | Промежуточный шаг: Xorg/KWin на Intel (вобрано) |
| `enable_d3cold.sh` | Промежуточный шаг: `GpuInitOnProbe` + `modeset=0` (вобрано) |
| `README.md` | Этот документ |

Старые три скрипта оставлены для истории; запускать нужно только
`setup-d3cold.sh`.
