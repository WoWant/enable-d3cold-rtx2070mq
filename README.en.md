[Русский](README.md) | **English**

# NVIDIA RTX 2070 Max-Q: D3cold sleep (0 W)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Hybrid laptop **MSI P65** (Intel UHD 630 + NVIDIA RTX 2070 Max-Q, Turing TU106M)
running **Arch Linux + KDE Plasma Wayland + SDDM**.

The `setup-d3cold.sh` script brings the system to a state where:

- the discrete NVIDIA GPU **enters D3cold** (fully powered off, ~0 W) when idle;
- the **chassis LED turns white** (orange = GPU powered);
- games and compute workloads run on NVIDIA on demand, and the GPU goes back
  to sleep afterwards;
- the desktop, KWin and the SDDM login screen run on Intel and **do not wake**
  the discrete GPU.

---

## 1. Symptoms this fixes

1. **KWin freezes** (`The main thread was hanging temporarily!`, mouse/UI
   stalling for 1–2 seconds, especially during video playback and window
   switching). Cause: nouveau on Turing reloads the GSP firmware on every GPU
   wake (~0.5–1.5 s), and KWin touches the dGPU at that moment.
2. **The discrete GPU never sleeps** with the proprietary driver: shorter
   battery life, the LED stays orange.

## 2. Root cause

### 2.1. Freezes (nouveau)

When compositing, KWin synchronizes frames with the dGPU
(`drmSyncobjEventfd`). If the GPU is in D3cold, nouveau wakes it: PCIe
retraining + GSP reload ≈ 1.5 s (or ≈0.5 s from D3hot). KWin's main thread is
blocked meanwhile.

### 2.2. The GPU never slept (nvidia-open)

Five independent causes stacked up:

| # | Cause | Fix |
|---|-------|-----|
| 1 | On **Turing**, RTD3 is disabled by default (unlike Ampere/Ada) | `NVreg_DynamicPowerManagement=0x01` |
| 2 | **Linux 7.3 bug** (`kthread` in `nullfs`): the driver cannot read `/sys/.../config` during probe and silently disables RTD3 | re-probe the GPU from process context (unbind/bind) |
| 3 | **620.x driver**: `NVreg_GpuInitOnProbe=2` (default) initializes the GPU at probe time and **never releases** the `NV_DYNAMIC_PM_COARSE` reference | `NVreg_GpuInitOnProbe=0` |
| 4 | `nvidia_drm modeset=1` keeps the GPU open through NVKMS (+1 MiB VRAM) | `nvidia_drm modeset=0 fbdev=0` |
| 5 | Holders of `/dev/nvidia*` (SDDM Xorg greeter, KWin) keep `usage_count` above 0 | Xorg → Intel only; KWin → Mesa/Intel only |
| 6 | KWin 6.8.2 `GpuManager` scans **all** render nodes, including `renderD129` (NVIDIA), and opens `/dev/nvidia*` | `KWIN_RENDER_NODES=/dev/dri/intel-render` |
| 7 | Unwired Turing PCI functions `01:00.2` (USB xHCI), `01:00.3` (UCSI) and `01:00.1` (Audio) wake the GPU out of `D3cold` on any USB scan (`adb`, `lsusb`, `fwupd`) and on S3 entry with `0 ms` autosuspend delay → `PGOF → PGON` power bounce and a hard BIOS hang in `\_SB.PCI0.PGON` (`AE_AML_LOOP_TIMEOUT`, yellow LED, 100% fans) | Remove `.1/.2/.3` via udev (`ATTR{remove}="1"` per NVIDIA README §21H), `autosuspend_delay_ms=3000` on bridge `00:01.0`, `90-nvidia-d3cold-s3` sleep hook |

Any single cause 1–6 blocks D3cold, and cause 7 leads to hard system lockups when waking from D3cold.

## 3. Final working configuration

```
/etc/modprobe.d/blacklist-nouveau.conf   blacklist nouveau
/etc/modprobe.d/nvidia.conf              RTD3 + GpuInitOnProbe + modeset=0 + blacklist i2c/ucsi
/usr/local/sbin/nvidia-rtd3-rebind       re-probe GPU + remove .1/.2/.3 + 3000 ms bridge delay
/etc/systemd/system/nvidia-rtd3.service  run re-probe before display-manager
/usr/lib/systemd/system-sleep/90-nvidia-d3cold-s3
                                         safe D3cold <-> S3 (deep) transition
/etc/udev/rules.d/80-nvidia-pm.rules     remove .1/.2/.3 + power/control=auto on bind
/etc/udev/rules.d/70-intel-drm.rules     stable /dev/dri/intel-card and intel-render symlinks
/etc/X11/xorg.conf.d/10-intel-only.conf  Xorg greeter on Intel only
~/.config/environment.d/kwin-gpu.conf    KWIN_DRM_DEVICES + KWIN_RENDER_NODES -> Intel
~/.config/systemd/user/plasma-kwin_wayland.service.d/egl.conf
                                         KWin does not load libEGL_nvidia
```

Plus: the `nvidia-open` driver, `vulkan-nouveau` removed,
`nouveau.config=NvGspRm=...` stripped from the kernel command line, and the old
workarounds removed (`51-nvidia-usb-power.rules`, `71-nvidia-d3hot.rules`,
`nvidia-usb-power.service`, `POWERDEVIL_NO_DDCUTIL`).

## 4. Requirements

- Arch Linux (tested on kernel **7.3.4**; 7.2.x does not have the nullfs bug,
  but the rest still applies).
- **Intel + NVIDIA Turing** hybrid (RTX 20xx Mobile). On Ampere/Ada the
  `NVreg_DynamicPowerManagement` part is not needed (RTD3 is on by default).
- **KDE Plasma 6 Wayland** + SDDM (Xorg greeter).
- Internal display wired to Intel (on this model — yes, eDP on i915).
- `sudo` access and internet for `pacman`.

## 5. Quick start

```bash
cd ~/Projects/enable_d3cold_rtx2070mq
sudo bash setup-d3cold.sh
sudo reboot
```

`--no-steam` skips the Steam setup.

> The script switches the GPU driver and rebuilds the initramfs. A **reboot is
> required** afterwards. If something goes wrong — see "Rollback".

## 6. What the script does (and how to reproduce it manually)

The script is idempotent: re-running it is safe.

### Step 1. System update

```bash
sudo pacman -Syu
```

Why: `nvidia-open` is built against the current `linux` package. If the kernel
is behind, the module will not load (that is exactly what happened the first
time).

### Step 2. Driver installation

```bash
sudo pacman -S --needed nvidia-open nvidia-utils nvidia-settings nvidia-prime \
    vulkan-intel lib32-vulkan-intel lib32-nvidia-utils
```

- `nvidia-open` — open NVIDIA kernel modules (Turing is supported);
- `nvidia-prime` — provides `prime-run`;
- `vulkan-intel` — Vulkan on Intel (needed so the Steam client does not pick
  NVIDIA);
- `lib32-*` — for 32-bit games (only with multilib enabled).

### Step 3. Remove nouveau Vulkan

```bash
sudo pacman -Rns vulkan-nouveau lib32-vulkan-nouveau
```

### Step 4. Blacklist nouveau and drop its kernel parameter

```bash
echo 'blacklist nouveau' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
sudo sed -i -E 's/ nouveau\.config=NvGspRm=[01]//g' /boot/loader/entries/*.conf
```

For GRUB — do the same in `/etc/default/grub`, then
`sudo grub-mkconfig -o /boot/grub/grub.cfg`.

### Step 5. Remove old workarounds

```bash
sudo rm -f /etc/udev/rules.d/51-nvidia-usb-power.rules
sudo rm -f /etc/udev/rules.d/71-nvidia-d3hot.rules
sudo rm -f /etc/modprobe.d/blacklist-nvidia-i2c.conf
sudo systemctl disable --now nvidia-usb-power.service 2>/dev/null
sudo rm -f /etc/systemd/system/nvidia-usb-power.service
sudo sed -i '/^POWERDEVIL_NO_DDCUTIL=/d' /etc/environment
```

Why: `51-nvidia-usb-power.rules` sets `power/control=on` for all NVIDIA
devices, and `71-nvidia-d3hot.rules` (`d3cold_allowed=0`) **prevents** D3cold.
The rest were failed experiments that do not affect the result.

### Step 6. Driver parameters

```bash
sudo tee /etc/modprobe.d/nvidia.conf >/dev/null <<'EOF'
options nvidia NVreg_DynamicPowerManagement=0x01 NVreg_GpuInitOnProbe=0
options nvidia_drm modeset=0 fbdev=0
blacklist i2c_nvidia_gpu
blacklist ucsi_ccg
EOF
```

- `NVreg_DynamicPowerManagement=0x01` — coarse-grained RTD3 for Turing.
- `NVreg_GpuInitOnProbe=0` — the driver does not initialize the GPU at probe
  time and does not hold a power reference.
- `modeset=0 fbdev=0` — `nvidia_drm` does not open the GPU through NVKMS.
- `blacklist i2c_nvidia_gpu` / `ucsi_ccg` — on the MSI P65 no physical Type-C
  port is wired to the NVIDIA GPU (`01:00.3` otherwise stalls boot with I2C
  timeout errors).

### Step 7. Linux 7.3 workaround (re-probe) + `PGON` freeze protection

```bash
sudo tee /usr/local/sbin/nvidia-rtd3-rebind >/dev/null <<'EOF'
#!/bin/bash
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

In addition, `/usr/lib/systemd/system-sleep/90-nvidia-d3cold-s3` is installed:
before entering S3 (`deep`) it wakes the GPU to `D0` in normal process context
(before user sessions are frozen and consoles/EC are stopped), and restores
`power/control=auto` after resume.

### Step 8. Remove unwired `.1/.2/.3` PCI functions and allow runtime PM in udev

```bash
sudo tee /etc/udev/rules.d/80-nvidia-pm.rules >/dev/null <<'EOF'
ACTION=="add",    SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", ATTR{remove}="1"
ACTION=="add",    SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", ATTR{remove}="1"
ACTION=="add",    SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ATTR{remove}="1"
ACTION=="bind",   SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind",   SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
EOF
```

Why remove `0x0c0330` (`01:00.2` USB xHCI), `0x0c8000` (`01:00.3` UCSI) and
`0x040300` (`01:00.1` Audio) — per NVIDIA's official documentation (`README`
§21H): on the MSI P65 no physical Type-C port is wired to the NVIDIA GPU, but
leaving `01:00.2` on the bus creates empty USB buses `usb3`/`usb4` with
`autosuspend_delay_ms=0`. Any USB scan (`adb`, `lsusb`, `fwupd`) wakes the GPU
through them without opening `/dev/nvidia*`, causing a `PGOF → PGON` power
bounce that hangs the BIOS `\_SB.PCI0.PGON` method with a 30-second
`AE_AML_LOOP_TIMEOUT`.

### Step 9. SDDM Xorg greeter — Intel only

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

`BusID` corresponds to your Intel GPU (`0000:00:02.0` → `PCI:0:2:0`). The script
computes it automatically.

### Step 10. KWin — Intel only

First, a stable symlink to the Intel card (no colons in the name — important
for the next part):

```bash
sudo tee /etc/udev/rules.d/70-intel-drm.rules >/dev/null <<'EOF'
SUBSYSTEM=="drm", KERNEL=="card*",    KERNELS=="0000:00:02.0", SYMLINK+="dri/intel-card"
SUBSYSTEM=="drm", KERNEL=="renderD*", KERNELS=="0000:00:02.0", SYMLINK+="dri/intel-render"
EOF
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=drm --action=add
sudo udevadm settle
ls -l /dev/dri/intel-card /dev/dri/intel-render
```

Restrict KWin to the Intel GPU and Intel render node:

```bash
mkdir -p ~/.config/environment.d
cat > ~/.config/environment.d/kwin-gpu.conf <<'EOF'
KWIN_DRM_DEVICES=/dev/dri/intel-card
KWIN_RENDER_NODES=/dev/dri/intel-render
EOF
```

And, most importantly, KWin must not load the NVIDIA EGL vendor:

```bash
mkdir -p ~/.config/systemd/user/plasma-kwin_wayland.service.d
cat > ~/.config/systemd/user/plasma-kwin_wayland.service.d/egl.conf <<'EOF'
[Service]
Environment=__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
EOF
```

Why:
- `KWIN_DRM_DEVICES` restricts the DRM backend (which `/dev/dri/card*` to use);
- `KWIN_RENDER_NODES` restricts `GpuManager`: in KWin 6.8.2 it scans **all**
  render nodes and otherwise opens NVIDIA's `renderD129`, and with it
  `/dev/nvidia*`;
- the EGL drop-in stops KWin from loading `libEGL_nvidia`.

All three complement each other.

### Step 11. Steam (optional)

The Steam client (`steamwebhelper`) should not run on the dGPU:

```bash
mkdir -p ~/.local/share/applications
cp /usr/share/applications/steam.desktop ~/.local/share/applications/steam.desktop
sed -i 's/^PrefersNonDefaultGPU=.*/PrefersNonDefaultGPU=false/; s/^X-KDE-RunOnDiscreteGpu=.*/X-KDE-RunOnDiscreteGpu=false/' \
    ~/.local/share/applications/steam.desktop
```

And in `~/.local/share/Steam/ubuntu12_64/steamwebhelper_sniper_wrap.sh`,
**before** the `exec ./steamwebhelper ...` line, add:

```bash
export __GLX_VENDOR_LIBRARY_NAME=mesa
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/lib/pressure-vessel/overrides/share/glvnd/egl_vendor.d/50_mesa.json
export __EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES=
export VK_DRIVER_FILES=/usr/lib/pressure-vessel/overrides/share/vulkan/icd.d/intel_icd.json
export VK_ICD_FILENAMES=/usr/lib/pressure-vessel/overrides/share/vulkan/icd.d/intel_icd.json
```

### Step 12. Rebuild the initramfs

```bash
sudo mkinitcpio -P
```

Needed so that `blacklist nouveau` gets into the initramfs.

### Step 13. Reboot

```bash
sudo reboot
```

## 7. Verification

> **Important:** `nvidia-smi` itself wakes the GPU. To check sleep, use sysfs
> only.

```bash
# 1. PCI state of the GPU (should be suspended / D3cold)
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status   # suspended
cat /sys/bus/pci/devices/0000:01:00.0/power_state            # D3cold

# 2. All GPU functions (video, audio, USB, UCSI) are asleep
for d in /sys/bus/pci/devices/0000:01:00.*; do
    echo "$d: $(cat $d/power/runtime_status) / $(cat $d/power_state)"
done

# 3. Nobody holds /dev/nvidia* (should be empty)
sudo fuser -v /dev/nvidia*

# 4. The chassis LED is white
```

If the GPU has woken up, RTD3 can be checked like this (while the GPU is
active):

```bash
cat /proc/driver/nvidia/gpus/0000:01:00.0/power
# Runtime D3 status: Enabled (coarse-grained)
```

While the GPU is in D3cold, some fields of that file show `?` — this is normal
(the driver cannot query a powered-off chip).

## 8. Running games and compute workloads on NVIDIA

```bash
# From a terminal
prime-run glxinfo | grep "OpenGL renderer"
prime-run blender

# Steam: game Properties → General → Launch Options
prime-run %command%
```

- `CUDA`, `OpenCL` and `Vulkan` compute work out of the box: they wake the GPU
  through `/dev/nvidia*` and release it when the process exits.
- While a program is running, the LED is orange and `runtime_status` is
  `active`. About 10–15 seconds after it exits, the GPU is back to
  `suspended` / `D3cold`.

### Important limitation: native Wayland on NVIDIA

With `nvidia_drm modeset=0` (required for D3cold), **native Wayland rendering
on NVIDIA does not work**. Verified: `vkcube --wsi wayland` and `mpv
--gpu-context=wayland` with the NVIDIA ICD crash (the NVIDIA driver needs KMS
for Wayland dma-buf). KWin is not involved.

What does work:
- **Xwayland** (the default for Steam/Proton) — OpenGL and Vulkan;
- `CUDA`/`OpenCL` and any compute;
- `prime-run <app>` for X11/GLX apps;
- Vulkan through Xwayland (`vkcube --wsi xcb` on NVIDIA — verified).

If you specifically need a native-Wayland game on NVIDIA: either run it through
Xwayland (do not enable `PROTON_ENABLE_WAYLAND`), or temporarily set
`nvidia_drm modeset=1` (the GPU will not enter D3cold in that session).

## 9. Rollback

Full rollback to nouveau (the freezes will return, but the system will work):

```bash
sudo rm -f /etc/modprobe.d/nvidia.conf /etc/modprobe.d/blacklist-nouveau.conf
sudo rm -f /etc/udev/rules.d/80-nvidia-pm.rules
sudo rm -f /etc/systemd/system/nvidia-rtd3.service
sudo rm -f /usr/local/sbin/nvidia-rtd3-rebind
sudo rm -f /usr/lib/systemd/system-sleep/90-nvidia-d3cold-s3
sudo rm -f /etc/X11/xorg.conf.d/10-intel-only.conf
rm -f ~/.config/systemd/user/plasma-kwin_wayland.service.d/egl.conf
sudo pacman -S --needed vulkan-nouveau lib32-vulkan-nouveau
sudo mkinitcpio -P
sudo reboot
```

If the login screen does not come up after the setup, remove
`10-intel-only.conf` and reboot:

```bash
sudo rm /etc/X11/xorg.conf.d/10-intel-only.conf
sudo reboot
```

## 10. Important caveats

1. **External monitors on the NVIDIA ports** (HDMI/DP on the card itself) will
   not work with `nvidia_drm modeset=0`. If you need them, set `modeset=1`
   (and the GPU will most likely stop entering D3cold while a monitor is
   attached).
2. **`linux-zen`**: `nvidia-open` is built for the `linux` kernel only. For
   `linux-zen`, install `nvidia-open-dkms` + `linux-zen-headers` (otherwise
   there will be no NVIDIA driver in zen, and nouveau is already blacklisted).
3. **Steam updates** overwrite `steamwebhelper_sniper_wrap.sh`. If the Steam
   client starts waking the GPU again, re-run the script.
4. **Battery**: at setup time its health was ~63%
   (`charge_full` 3314 of `charge_full_design` 5280 mAh), `cycle_count = 0`.
   Even with perfect GPU sleep, battery life is limited by wear.
5. **`nvidia-smi` wakes the GPU** — do not use it to check sleep.
6. `pcie_aspm=off` and `mem_sleep_default=s2idle` on the kernel command line are
   your pre-existing settings, unrelated to this task; the script does not
   touch them.

## 11. Repository files

| File | Purpose |
|------|---------|
| `setup-d3cold.sh` | The single setup script (use this one) |
| `fix_rtd3.sh` | Intermediate step: RTD3 + re-probe (merged into `setup-d3cold.sh`) |
| `fix_d3_sleep.sh` | Intermediate step: Xorg/KWin on Intel (merged) |
| `enable_d3cold.sh` | Intermediate step: `GpuInitOnProbe` + `modeset=0` (merged) |
| `fix-kwin-render-nodes.sh` | KWin 6.8.2 hotfix: `KWIN_RENDER_NODES` (after a KWin update) |
| `fix-d3cold-freeze.sh` | Hotfix for `PGON AE_AML_LOOP_TIMEOUT` hard freezes on USB scans (`adb`) and S3 (`deep`) |
| `README.md` | Russian README |
| `README.en.md` | This document |
| `LICENSE` | MIT License |

The three old scripts are kept for history; only `setup-d3cold.sh` needs to be
run.
