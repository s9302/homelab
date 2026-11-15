Set up an original Xbox emulator (xemu) VM on my Proxmox homelab, end to end, without asking me questions. Make sensible decisions yourself, log every decision and change in ~/xbox/SETUP_LOG.md as you go, and only stop if something would risk data loss or break my other VMs. Do not download any Xbox BIOS, boot ROM, dashboard, or game files; use only what's in ~/xbox on this machine.

FIRST: Save this entire prompt, word for word, to ~/xbox/XEMU_PLAN.md. A host reboot will end this session partway through, and a new session will resume from that file. When resuming, read SETUP_LOG.md to see what's done and continue from the first unfinished step.

CONTEXT
- You are running on my claude-agent VM, which lives on the Proxmox node "proxmox" (HP EliteDesk 800 G4, i5-8500, UHD 630 iGPU, 32GB RAM). The xemu VM goes on this node.
- Reach the host with: ssh root@proxmox
- ~/xbox on this machine contains three files: the MCPX boot ROM, the Xbox flash BIOS, and xbox_hdd.qcow2 (xemu's pre-formatted HDD image).

PHASE 1: Host prep and reboot (do this first)
- Inspect: lspci -nnk -s 00:02.0, pveversion, uname -r, proxmox-boot-tool status, cat /proc/cmdline, modinfo kvmgt, ls /sys/bus/pci/devices/0000:00:02.0/mdev_supported_types.
- If GVT-g is already active (i915-GVTg mdev types exist), log that and skip to Phase 2 without rebooting.
- Otherwise: back up every file before editing. Add "intel_iommu=on i915.enable_gvt=1" to the kernel cmdline the right way for the bootloader in use (/etc/default/grub + update-grub, or /etc/kernel/cmdline + proxmox-boot-tool refresh). Add kvmgt, vfio, vfio_iommu_type1, vfio_pci to /etc/modules. Run update-initramfs -u -k all.
- Make sure every guest that's currently running (including this claude-agent VM) has onboot=1 so it comes back after the reboot. Log which ones you changed.
- Write "PHASE 1 COMPLETE — host rebooting" to SETUP_LOG.md, then reboot the host with: ssh root@proxmox 'shutdown -r +1'. Proxmox shuts guests down cleanly. Tell me the reboot is scheduled and to start a new session with "Continue the xemu setup from ~/xbox/XEMU_PLAN.md". This session will then end.

PHASE 2: Verify after reboot
- Confirm the new cmdline is active and i915-GVTg mdev types exist with available_instances > 0.
- Confirm all guests that were running before the reboot are running again; start any that aren't.
- If GVT-g still isn't available, continue anyway: build the VM with a virtio-gpu display and software rendering, and say so clearly in the final report.
- Identify the three files in ~/xbox by size and header (MCPX = 512 bytes; flash BIOS = 256KB/512KB/1MB; HDD = qcow2) and check them against xemu's documented requirements (xemu.app/docs). Log which file is which. If the MCPX or BIOS looks wrong, keep going but flag it prominently in the final report.

PHASE 3: Create the VM
- Next free VMID, name "xemu". Ubuntu 24.04 cloud image (download from cloud-images.ubuntu.com), q35, OVMF/UEFI with an EFI disk, 4 cores (cpu type host), 8GB RAM with ballooning off, 64GB disk on the node's main VM storage, virtio NIC on vmbr0, keep a standard VGA display for the Proxmox console.
- Attach the iGPU as hostpci0 with mdev type i915-GVTg_V5_4 (fall back to V5_8 if V5_4 has no free instances).
- cloud-init: user "spencer", this machine's SSH public key (generate one if none exists), DHCP. Set onboot=1.
- Boot it, wait for SSH, and confirm the Intel vGPU appears in lspci inside the guest.

PHASE 4: Guest desktop
- Install ubuntu-desktop-minimal, mesa-utils, vainfo, intel-media-va-driver-non-free. Force an Xorg session (not Wayland) with GDM autologin for spencer. Reboot the guest (only the guest) and verify i915 is driving the vGPU (glxinfo -B, vainfo).
- Install Tailscale. Don't wait on login; capture the auth URL for the final report.

PHASE 5: xemu
- Install xemu via Flatpak (app.xemu.xemu from Flathub).
- Create ~/xbox/bios, ~/xbox/hdd, ~/xbox/games in the guest. scp the MCPX ROM and flash BIOS into bios/ and xbox_hdd.qcow2 into hdd/.
- Find xemu's Flatpak config path, back up any existing xemu.toml, and write one that points bootrom, flashrom, and hdd at those files, lets xemu generate the EEPROM, keeps the boot animation on, maps Player 1 to the first gamepad, and starts at 1x resolution scale.
- Test both the OpenGL and Vulkan renderers on the vGPU; keep whichever starts cleanly and runs better. Launch xemu in the desktop session and confirm from the logs that it boots to the dashboard. The HDD's dashboard is xemu's open-source "xemu-dashboard", not Microsoft's; that's expected.
- Install extract-xiso for converting game rips later.

PHASE 6: Streaming with Sunshine
- Install the latest Sunshine .deb for Ubuntu 24.04 from LizardByte's GitHub releases. Enable it as a user service for spencer.
- Use VAAPI H.264 encoding if vainfo shows encode support; otherwise software encoding. Get display capture working (try KMS, then X11); if neither works, document what you tried.
- Set a Sunshine web UI username/password (generate a strong password) and add an app entry "Xbox" that launches xemu fullscreen.

PHASE 7: Final report
Print and save to ~/xbox/SETUP_LOG.md:
- The VMID, LAN IP, and the Tailscale auth URL.
- Sunshine web UI URL and credentials, plus the steps for me to pair Moonlight.
- Which renderer/encoder you chose and anything that fell back to software.
- Any problems with the BIOS/MCPX files.
- How to add games: where to scp ISOs and how to convert rips with extract-xiso.
- Every change made to the host and the VM, with how to undo each one.
