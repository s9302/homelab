# xemu setup log

## Session 1 — 2026-10-15

### Pre-flight decisions
- The input files were actually in `~/Xbox` (capital X); `~/xbox` did not exist. **Decision:** created symlink `~/xbox -> Xbox` so the plan's paths work unchanged. Undo: `rm ~/xbox` (removes only the link).
- Saved the prompt verbatim to `~/xbox/XEMU_PLAN.md`.
- Input files (quick check, full verification is in Phase 2):
  - `mcpx_1.0.bin` — 512 B, SHA1 `5d270675b54eb8071b480e42d22a3015ac211cef` (the known-good MCPX 1.0 hash)
  - `Complex_4627.bin` — 1 MiB flash BIOS (`file` calls it "Excel BIFF"; false positive)
  - `xbox_hdd.qcow2` — qcow2 v3, 8 GiB virtual

### Phase 1 — host inspection (proxmox)
- iGPU 00:02.0 = Intel UHD 630 [8086:3e92], driver i915
- pve-manager 9.2.2, kernel 7.0.2-6-pve; kvmgt.ko present
- Bootloader: **GRUB** (`/etc/kernel/proxmox-boot-uuids` missing → not proxmox-boot-tool/systemd-boot)
- cmdline: `BOOT_IMAGE=/boot/vmlinuz-7.0.2-6-pve root=/dev/mapper/pve-root ro quiet`
- No mdev_supported_types → GVT-g **not** active → reboot path taken
- DMAR/VT-d present in firmware
- Cluster "homelab" 3 nodes, quorate; no HA resources → rebooting one node keeps quorum (2/3)
- Running guests on this node: VM 102 wazuh, VM 103 claude-agent, CT 202 uptime

### Phase 1 — host changes (all backups in `proxmox:/root/xemu-backups/*.20261014-204613`)
| Change | Undo |
|---|---|
| `/etc/default/grub`: `GRUB_CMDLINE_LINUX_DEFAULT="quiet"` → `"quiet intel_iommu=on i915.enable_gvt=1"`, then `update-grub` | `cp /root/xemu-backups/grub.20261014-204613 /etc/default/grub && update-grub` |
| `/etc/modules`: appended `kvmgt`, `vfio`, `vfio_iommu_type1`, `vfio_pci` | `cp /root/xemu-backups/modules.20261014-204613 /etc/modules` |
| `update-initramfs -u -k all` (regenerated initrd for 7.0.2-6-pve) | re-run `update-initramfs -u -k all` after the two restores above, then reboot |
| VM 102 wazuh: `onboot` unset → `1` | `qm set 102 --delete onboot` |
| VM 103 claude-agent: `onboot` unset → `1` | `qm set 103 --delete onboot` |
| CT 202 uptime: already `onboot: 1`, unchanged | — |

Decision: `/etc/modules` is marked obsolete on PVE 9 but still works; used it as instructed rather than `/etc/modules-load.d/`.

Guests running before reboot (verify in Phase 2): **VM 102, VM 103, CT 202**

PHASE 1 COMPLETE — host rebooting

## Session 2 — 2026-10-15 (after host reboot)

### Phase 2 — verification
- cmdline active: `... quiet intel_iommu=on i915.enable_gvt=1`
- kvmgt, vfio, vfio_iommu_type1, vfio_pci loaded
- mdev types: `i915-GVTg_V5_4` avail=1 (1920x1200, 128MB/512MB GM), `i915-GVTg_V5_8` avail=2 (1024x768)
- Guests back up: VM 102 wazuh ✅, VM 103 claude-agent ✅, CT 202 uptime ✅ — nothing to start
- Files (identified by size + header):
  | File | Role | Size | SHA1 | Notes |
  |---|---|---|---|---|
  | `mcpx_1.0.bin` | MCPX boot ROM | 512 B | `5d270675…1cef` | Matches xemu's documented good MCPX 1.0 hash ✅ |
  | `Complex_4627.bin` | Flash BIOS | 1 MiB | `6639b669…3a5e` | 256 KiB image mirrored 4x; X-code table at 0x0, reset vector at end. "Complex 4627" is a **modded** 4627 BIOS, not stock retail — works with MCPX 1.0, xemu accepts it; noted, not a blocker |
  | `xbox_hdd.qcow2` | HDD | 1.6 MB (8 GiB virtual) | `60d614cc…ff58` | qcow2 v3 magic `QFI\xfb` ✅ |

### Decisions for Phase 3
- **RAM: 10240 MB instead of the plan's 8 GB.** User freed RAM by shrinking claude-agent and asked for more in xemu. GVT-g/vfio pins all guest RAM, so no overcommit: 31 GiB host − wazuh 8 − claude-agent 7 − CT 202 1 − ZFS ARC cap 3.1 − ~2 host = ~10 GiB. 12 GB would risk OOM on the host.
- Disk storage: `Storage_1` (zfspool, 7% used, holds claude-agent's disk). local-lvm exists but is empty/unused.
- VMID: 105 (`pvesh get /cluster/nextid`).
- SSH key: existing `~/.ssh/id_ed25519.pub` on claude-agent.

PHASE 2 COMPLETE

### Phase 3 — VM 105 "xemu"
- Cloud image: `proxmox:/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img` (SHA256 verified vs Ubuntu's SHA256SUMS)
- `qm create 105`: q35, OVMF (efidisk0 4m, no pre-enrolled keys), cpu host ×4, **10240 MB, balloon 0**, virtio net on vmbr0, vga std, agent enabled, onboot=1
- scsi0 = imported cloud image on Storage_1, resized to 64G (iothread, discard, ssd)
- cloud-init on Storage_1: user spencer, key = claude-agent's `id_ed25519.pub` (copied to `proxmox:/root/xemu-backups/claude-agent.pub`), DHCP
- hostpci0 = `0000:00:02.0,mdev=i915-GVTg_V5_4,pcie=1` (V5_4 had 1 free instance; now 0)
- Start warning `VFIO dma-buf not supported in kernel` — only affects displaying the vGPU framebuffer in the Proxmox console; harmless here
- Guest LAN IP: **<lan-ip>** (DHCP); vGPU visible in guest: `01:00.0 Intel UHD 630 [8086:3e92]` ✅
- claude-agent can't reach the LAN IP directly (Tailscale anti-spoof drops 100.64/10 from the LAN), so added `Host xemu` to claude-agent `~/.ssh/config` jumping via proxmox to the IPv6 link-local. Undo: delete that block.
- Undo VM entirely: `qm stop 105 && qm destroy 105 --purge` (frees the GVT-g instance)

PHASE 3 COMPLETE

### Phase 4 — guest desktop
- apt full-upgrade + `linux-generic ubuntu-desktop-minimal mesa-utils vainfo intel-media-va-driver-non-free qemu-guest-agent vulkan-tools mesa-vulkan-drivers flatpak`
  - **Decision:** added `linux-generic` — the cloud image ships `linux-image-virtual`, which has no i915 module. Also added qemu-guest-agent (VM has agent=1), Vulkan tools/drivers (needed for the renderer test), flatpak (Phase 5).
- `/etc/gdm3/custom.conf` (backup `custom.conf.bak-xemu`): `WaylandEnable=false`, autologin spencer
- **New `/etc/X11/xorg.conf.d/10-gvtg.conf`**: modesetting on `BusID PCI:1:0:0`. Needed because the QEMU std VGA is the boot VGA and Xorg otherwise picks it. First version also had `Option "kmsdev"` with a by-path symlink, which made Xorg fail ("Screen 0 deleted because of no matching config section"); removed it. Undo: `sudo rm /etc/X11/xorg.conf.d/10-gvtg.conf`
- `systemctl set-default graphical.target`
- Guest rebooted twice (guest only). Verified:
  - kernel 6.8.0-147-generic, `01:00.0` driver **i915**
  - vGPU virtual monitor on **DP-3, 1920x1200@60**
  - `glxinfo -B`: direct rendering, Accelerated: yes, **Mesa Intel UHD Graphics 630 (CFL GT2)**, GL 4.6 (Mesa 25.2.8)
  - `vulkaninfo`: Intel UHD 630 (Mesa ANV) ✅
  - `vainfo`: iHD 24.1.0 — **H.264 EncSlice/EncSliceLP ✅**, HEVC Main/Main10 encode ✅
- Tailscale 1.104.1 installed (official install script, `tailscale up --hostname=xemu`), **not logged in**; auth URL: https://login.tailscale.com/a/36e8cdd01985f
  - Note: the tailnet uses a least-privilege ACL policy; the xemu device will need ACL rules for Moonlight (TCP 47984,47989,48010; UDP 47998-48000,48010) and the Sunshine web UI (TCP 47990) from your devices.
  - Undo: `sudo apt purge tailscale`

PHASE 4 COMPLETE

### Phase 5 — xemu
- Flathub remote added (system), `app.xemu.xemu` **0.8.136** installed (runtime org.freedesktop.Platform 26.08). Undo: `sudo flatpak uninstall app.xemu.xemu`
- The Flatpak's sandbox has `filesystems=host:ro`, but xemu must write to the HDD image → **`flatpak override --user --filesystem=/home/spencer/xbox app.xemu.xemu`** (read-write on ~/xbox only). Undo: `flatpak override --user --reset app.xemu.xemu`
- Guest `~/xbox/{bios,hdd,games}` created; files scp'd, SHA1s match the originals
- Config: `~/.var/app/app.xemu.xemu/data/xemu/xemu/xemu.toml` (none existed before, so nothing to back up). Settings: bootrom/flashrom/hdd paths, show_welcome=false, boot animation on (default), surface_scale 1 (default), update check off, games_dir=~/xbox/games, renderer OPENGL.
  - EEPROM: left unset → xemu generated `eeprom.bin` (256 B) in the config dir and wrote its path into the toml
  - **Controller decision:** xemu auto-binds a new controller to the first *free* port, and only binds the keyboard if a port names it. So **port1 is left unbound** → the first gamepad (including Moonlight's virtual pad) becomes Player 1; keyboard is a fallback on port2.
  - **Gotcha:** xemu rewrites xemu.toml on exit and drops every value that equals the default (e.g. `renderer = "OPENGL"`, `skip_boot_anim = false`). That's expected, not lost settings.
- Renderer test (launched in spencer's Xorg session, screenshots of the root window):
  - OpenGL: GL 4.6 Mesa 26.2.2 on UHD 630, boots to **xemu-dashboard main menu** ✅, ~90% of one core idling at the dashboard
  - Vulkan: loader picked `Intel(R) UHD Graphics 630` (libvulkan_intel), boots to dashboard ✅, ~117% CPU
  - (The first "Vulkan" pass was really OpenGL because of the toml gotcha above; re-ran it properly.)
  - **Chose OpenGL**: both clean, OpenGL lighter, xemu's default/most mature backend. Switch in xemu: Settings → Display → Renderer.
- Suppressed Ubuntu's first-login welcome wizard (`~/.config/gnome-initial-setup-done`) so it doesn't sit over the stream
- **extract-xiso v2.7.1** built from github.com/XboxDev/extract-xiso @3f5b62c (not packaged for 24.04) → `/usr/local/bin/extract-xiso`. Added build-essential, cmake, git. Undo: `sudo rm /usr/local/bin/extract-xiso`
- Also installed x11-apps + imagemagick (screenshots for verification)

PHASE 5 COMPLETE

### Phase 6 — Sunshine
- Sunshine **v2026.914.233613** `sunshine_2026.914.233613-1+ubuntu24.04_amd64.deb` from LizardByte GitHub releases; SHA256 `c38e9c70…292c21` matches GitHub's published digest. Installs with `cap_sys_admin,cap_sys_nice` + udev rule 60-sunshine.rules (uinput ACL for the seat user ✅)
- User service `app-dev.lizardbyte.app.Sunshine.service` enabled for spencer (starts with the graphical session). Undo: `systemctl --user disable --now app-dev.lizardbyte.app.Sunshine.service`; `sudo apt purge sunshine`
- `~/.config/sunshine/sunshine.conf`: `encoder = vaapi`, `adapter_name = /dev/dri/renderD128`, `capture = kms`, `sunshine_name = xemu`
  - **Capture: KMS works first try** — card1 (i915 vGPU), connector 122 (DP-3), cursor plane found. X11 fallback not needed.
  - **Encoder: VAAPI** — h264_vaapi + hevc_vaapi found. No software fallback. (AV1 "No usable encoding profile" error is expected: UHD 630 has no AV1 encode.)
- `~/.config/sunshine/apps.json`: "Desktop" + **"Xbox" → `flatpak run app.xemu.xemu -full-screen`** (verified fullscreen launch to the dashboard)
- Web UI creds set with `sunshine --creds`; verified 200 with them and 401 with a wrong password
- **GNOME idle blank/lock/suspend disabled** (gsettings): spencer has no password (cloud-init locks it), so a locked screen could never be unlocked over the stream. Undo: `gsettings reset org.gnome.desktop.session idle-delay` (and the screensaver/power keys)
- Final unattended guest reboot test: autologin ✅, Sunshine active ✅, KMS+VAAPI ✅
- Tailscale was still logged out after the reboot, so I generated a fresh auth URL (the earlier one is superseded)

PHASE 6 COMPLETE

---

# PHASE 7 — FINAL REPORT (2026-10-15)

## The VM
- **VMID 105, name `xemu`** on node proxmox: q35/OVMF, 4× host CPU, **10 GB RAM (balloon off)**, 64 GB on Storage_1, GVT-g vGPU `i915-GVTg_V5_4`, onboot=1
- **LAN IP:** <lan-ip> (DHCP; MAC xx:xx:xx:xx:xx:xx. Consider a DHCP reservation)
- SSH: `spencer@` with claude-agent's key. From claude-agent use `ssh xemu` (jumps via proxmox, since the tailnet anti-spoof rule blocks the LAN IP)
- **Tailscale auth URL:** https://login.tailscale.com/a/172427df011dd2 (open it to add the VM to the tailnet; if it has expired, run `sudo tailscale up --hostname=xemu` in the VM for a new one)

## Sunshine / Moonlight
- **Web UI:** https://<lan-ip>:47990 (or https://xemu:47990 once on Tailscale). Self-signed cert, so accept the warning
- **Username:** `spencer`  **Password:** `REDACTED (in Vaultwarden / ask Spencer)`
- **Pairing Moonlight:**
  1. Install Moonlight on the client. On the same LAN it should auto-discover "xemu" (mDNS); otherwise use + Add Host → <lan-ip> (or `xemu` via Tailscale)
  2. Click the host → Moonlight shows a 4-digit PIN
  3. In the Sunshine web UI → **PIN** tab → enter the PIN plus a device name → Send
  4. Launch **"Xbox"**. xemu starts fullscreen. Plug the gamepad into the client *before* launching: it becomes Player 1
  - Over Tailscale: the tailnet ACL is least-privilege, so allow your devices → xemu on TCP 47984, 47989, 47990, 48010 and UDP 47998-48000, 48010

## Renderer / encoder
- xemu renderer: **OpenGL** (hardware, UHD 630 vGPU). Vulkan also works on the vGPU but used more CPU; switch with Settings → Display → Renderer
- Sunshine: **KMS capture + VAAPI H.264/HEVC** on the vGPU
- **Nothing fell back to software.**

## BIOS / MCPX
- MCPX `mcpx_1.0.bin`: correct (512 B, known-good 1.0 SHA1) ✅
- Flash `Complex_4627.bin`: valid 1 MiB image that boots in xemu ✅. FYI it's a **modded "Complex" 4627 BIOS, not stock retail**. Fine for xemu; if a game misbehaves, a retail 4627/5838 dump is the thing to try
- HDD: xemu's pre-built image with the open-source **xemu-dashboard** (expected), boots to its main menu ✅

## Adding games
- From claude-agent: `scp Game.iso xemu:xbox/games/` (once Tailscale is up, `scp Game.iso spencer@xemu:xbox/games/` from any of your devices)
- xemu needs **XISO** format. Rips from Redump (full disc image) must be converted in the VM:
  - `extract-xiso -r ~/xbox/games/Game.iso`: rewrites in place as an XISO (makes `Game.iso.old` backup; delete it after testing)
  - Folder of extracted files: `extract-xiso -c ~/xbox/games/GameFolder ~/xbox/games/Game.iso`
- Load: in xemu, Machine → Load Disc (or Ctrl+O) → pick from ~/xbox/games

## Every change, with undo
### Host (proxmox), Session 1
- `/etc/default/grub` + update-grub: added `intel_iommu=on i915.enable_gvt=1` → `cp /root/xemu-backups/grub.20261014-204613 /etc/default/grub && update-grub`
- `/etc/modules`: kvmgt vfio vfio_iommu_type1 vfio_pci → `cp /root/xemu-backups/modules.20261014-204613 /etc/modules`
- `update-initramfs -u -k all` → rerun after the restores above, then reboot
- VM 102 and VM 103 onboot → 1 → `qm set 102 --delete onboot` / `qm set 103 --delete onboot`
### Host, Session 2
- Downloaded `/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img` (+ `SHA256SUMS.noble`) → `rm` them
- `/root/xemu-backups/claude-agent.pub` (cloud-init key copy) → `rm`
- **VM 105** (disks vm-105-disk-0/1 + cloudinit on Storage_1, GVT-g instance) → `qm stop 105 && qm destroy 105 --purge`
### claude-agent
- `~/xbox → Xbox` symlink → `rm ~/xbox`
- `~/.ssh/config` `Host xemu` block → delete it
### Guest (VM 105)
- Packages: linux-generic, ubuntu-desktop-minimal, mesa-utils, vainfo, intel-media-va-driver-non-free, qemu-guest-agent, vulkan-tools, mesa-vulkan-drivers, flatpak, build-essential, cmake, git, x11-apps, imagemagick, tailscale, sunshine (all removable with apt purge; or just destroy the VM)
- `/etc/gdm3/custom.conf` → `sudo cp /etc/gdm3/custom.conf.bak-xemu /etc/gdm3/custom.conf`
- `/etc/X11/xorg.conf.d/10-gvtg.conf` → `sudo rm` it
- default target graphical → `sudo systemctl set-default multi-user.target`
- Flathub remote + app.xemu.xemu + user override → `flatpak override --user --reset app.xemu.xemu; sudo flatpak uninstall app.xemu.xemu`
- `~/.var/app/app.xemu.xemu/data/xemu/xemu/{xemu.toml,eeprom.bin}` → delete (xemu recreates defaults)
- `~/xbox/{bios,hdd,games}` → delete
- `/usr/local/bin/extract-xiso` → `sudo rm`
- `~/.config/sunshine/{sunshine.conf,apps.json,sunshine_state.json}` + enabled user service → disable the service and delete the files
- `~/.config/gnome-initial-setup-done`, gsettings idle/lock/power → delete / `gsettings reset ...`

SETUP COMPLETE

## Update 2026-10-15 — use the Tailscale address
- Tailscale is logged in: **xemu = <xemu-tailnet-ip>** (MagicDNS `xemu`)
- **Sunshine web UI: https://xemu:47990 or https://<xemu-tailnet-ip>:47990.** Moonlight host: `xemu` / <xemu-tailnet-ip>
- The LAN IP <lan-ip> is **unreachable from any device running Tailscale**: the LAN is in 100.64.0.0/10 (CGNAT), which Tailscale claims, so clients route it into the tailnet and it goes nowhere. Only use the LAN IP from devices without Tailscale.
- Sunshine's web UI blocked actions from the Tailscale URL with a "CSRF Protection Error". Added `csrf_allowed_origins = https://xemu:47990,https://<xemu-tailnet-ip>:47990,https://xemu.tailnet-name.ts.net:47990,https://<lan-ip>:47990` to `~/.config/sunshine/sunshine.conf` (backup `sunshine.conf.bak-csrf`) and restarted the service. Verified: the xemu origin passes, a bogus origin is still rejected.
- Correction: the Sunshine password printed in the first chat summary was wrong; the one in this log is correct.
- **Sunshine crashed on first stream:** Moonlight negotiated HEVC, `hevc_vaapi` hit "Failed to end picture encode issue: 24 (internal encoding error)" on the GVT-g vGPU, and Sunshine aborted (SIGABRT), leaving xemu orphaned and an apport "problem detected" dialog. A standalone ffmpeg hevc_vaapi test passes, so it's Sunshine's HEVC path on GVT-g. **Fix:** `hevc_mode = 1` + `av1_mode = 1` (advertise H.264 only) in sunshine.conf (backup `sunshine.conf.bak-codec`). Killed the orphaned xemu and cleared /var/crash. Also installed `ffmpeg` (encode test). The 16:15 SIGSEGV was Sunshine crashing on `systemctl restart` (shutdown path), harmless.
