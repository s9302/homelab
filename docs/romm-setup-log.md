# RomM setup log

Started 2026-10-15 from claude-agent (VM 103 on proxmox). Target node: pve3.

## Pre-flight
- `~/roms` does not exist on claude-agent. No game or BIOS files were provided, so Step 5 import has nothing to copy. Folders are still created so files can be dropped in later.

## Decisions and changes (chronological)

### Step 1: pve3 inspection (read-only), 12:53 MDT
- pve-manager 9.2.2, kernel 7.0.2-6-pve, 4 cores, 7.6 GiB RAM (2.1 GiB used, 5.5 GiB available), 7.6 GiB host swap (1.4 GiB in use).
- Guests on pve3: LXC 100 vaultwarden, 101 alpine-nextcloud, 200 pihole, 201 web; VM 300 metasploitable2. All running.
- Storage: `local-lvm` (lvmthin, main guest storage) 141.5 GiB pool, 31.24% used, **97.3 GiB free** (102,027,254 KiB). `local` (dir on root LV) 59.9 GiB free, holds templates/ISOs only.
- **Library size decision:** 60% of 97.3 GiB free = 58.4 GiB, under the 150 GB cap -> **58G** mount point on `local-lvm`. Leaves ~39 GiB of the pool for other guests.
- **Caveat logged:** the pool is already thin-overcommitted (alpine-nextcloud's 250G volume is 13.7% used). With RomM, provisioned total = 8+250+4+8+8+16+58 = 352G on a 141.5G pool. Real usage after this is ~46G + whatever ROMs you add. Fine while Nextcloud stays small; watch `lvs pve/data` Data% and keep it under ~85%.
- **RAM decision:** guest memory limits on pve3 already sum to 8 GiB (2+2+1+1 LXC + 2 VM). RomM's 4 GiB is an LXC cap, not a reservation, so it only costs what RomM actually uses (typically under 1 GiB idle). Kept 4 GiB as specified; noted overcommit.
- Next free CTID (cluster-wide `pvesh get /cluster/nextid`): **106**.
- Template: `debian-12-standard_12.12-1_amd64.tar.zst` (not yet downloaded on pve3).
- pve3 timezone is already America/Denver.

### Step 2: LXC created, 12:55 MDT
- Downloaded template `debian-12-standard_12.12-1_amd64.tar.zst` to pve3 `local`.
- `pct create 106`: hostname romm, unprivileged, 2 cores, 4096 MB RAM, 512 MB swap, rootfs `local-lvm:vm-106-disk-0` 16G, mp0 `local-lvm:vm-106-disk-1` 58G at `/library` (backup=1 so vzdump includes it), features nesting=1,keyctl=1, net0 vmbr0 DHCP (Proxmox firewall off, same as other guests), onboot=1, timezone America/Denver.
- `dev0: /dev/net/tun` set at creation time for Tailscale (Step 3), so no restart was needed later.
- Root SSH keys seeded from pve3's `/etc/pve/priv/authorized_keys` (Spencer's MacBook key + sandbox key). No root password set; key-only login.
- Started; DHCP gave **<lan-ip>/10** on the apartment LAN.
- Inside CT: `apt-get update && full-upgrade`; installed curl, ca-certificates, gnupg. Timezone set to America/Denver (confirmed `date` shows MDT). Locale warnings from apt are cosmetic (ssh forwards LANG=en_US.UTF-8, which the template doesn't generate).

### Step 3: Tailscale, 12:56 MDT
- Installed Tailscale 1.104.1 via the official install script (adds pkgs.tailscale.com apt repo). tailscaled enabled.
- `tailscale up --hostname=romm` started in background (log `/root/ts-up.log` in CT). **Auth URL: https://login.tailscale.com/a/80f7458019df3**
- /dev/net/tun already passed through (Step 2), no CT restart required.
- Docker installed from Docker's official Debian repo (`/etc/apt/keyrings/docker.asc`, `/etc/apt/sources.list.d/docker.list`, bookworm stable): docker-ce 29.9.1, compose plugin v5.6.0, plus buildx/containerd. `hello-world` ran fine, so nesting/keyctl work in the unprivileged CT.

### Step 4: RomM deployed, 12:57 to 13:01 MDT
- Source: `rommapp/romm` `examples/docker-compose.example.yml` on master (fetched 2026-10-15). Latest release is **5.4.0** (2026-10-10); running image reports VERSION 5.4.0, digest `rommapp/romm@sha256:03295f95a629...`. Images: `rommapp/romm:latest` + `mariadb:latest` (kept upstream's `latest` tags so `docker compose pull && up -d` actually updates).
- `/opt/romm/docker-compose.yml` changes vs upstream:
  - Secrets are `${...}` references to `/opt/romm/.env` instead of inline.
  - Named volumes replaced with bind mounts: `/opt/romm/resources`, `/opt/romm/assets`, `/opt/romm/config` (empty `config.yml` created), `/opt/romm/redis-data`, and MariaDB data at `/opt/romm/mysql`. Everything except the library lives under /opt/romm, which makes backups one path.
  - Library: `/library:/romm/library`.
  - `SCAN_WORKERS=2`, `WEB_SERVER_CONCURRENCY=2` (CT has 2 cores; upstream default 4). `TZ=America/Denver` on both containers.
  - Added IGDB_CLIENT_ID/SECRET placeholders alongside upstream's ScreenScraper/RetroAchievements/SteamGridDB. All blank. Hasheous left on (upstream default, no key needed).
  - Added `ENABLE_RESCAN_ON_FILESYSTEM_CHANGE=true` (5 min debounce) and `ENABLE_SCHEDULED_RESCAN=true` at 03:00, so files you rsync in show up without a manual scan. Docs say the watcher is fine on local disk, which this is.
  - `restart: unless-stopped` on both (upstream default). Port `80:8080` (upstream default).
- `/opt/romm/.env`: ROMM_AUTH_SECRET_KEY (`openssl rand -hex 32`, 64 hex chars), DB_PASSWD and MARIADB_ROOT_PASSWORD (`openssl rand -hex 24` each). root:root, mode 600. Values were never printed or copied off the CT.
- Library layout per RomM 5.4.0 docs "Folder Structure", **Structure A** (the recommended, auto-detected one): `/library/roms/{gb,gbc,gba,nds,psp}` and `/library/bios/nds` (docs: DS firmware is `firmware.bin, bios9.bin, bios7.bin` in `bios/nds/`).
- Stack up: romm-db healthy, RomM logs "RomM is now available at http://0.0.0.0:8080", `GET /` = 200 on 127.0.0.1 and on the CT's LAN IP <lan-ip>:80. docker-proxy listens on 0.0.0.0:80.
- **LAN test caveat:** I couldn't test from a separate LAN client. Every lab machine (sandbox, pve3) runs Tailscale's anti-spoof rule (`100.64.0.0/10` not on tailscale0 = drop), and the apartment LAN is numbered in 100.64.0.0/10, so they drop the replies. Confirmed instead from inside the CT against its own LAN IP. A phone or laptop on the building Wi-Fi without Tailscale should reach http://<lan-ip>/.
- **Security decision: claimed the first-run admin account myself.** RomM's setup wizard lets whoever opens it first create the admin, and port 80 sits on a shared apartment LAN with ~66 other residents' devices. Created admin `spencer` (email you@example.com) via `POST /api/users` with a random password; wizard is now closed (`SHOW_SETUP_WIZARD:false`). Credentials: `/opt/romm/admin-initial-credentials.txt` (root, 600). Change the password after first login.
- **LAN exposure note:** after Tailscale logs in, its anti-spoof rule protects the CT's own ports (SSH etc.), but Docker-published port 80 is DNAT'ed through FORWARD, not INPUT, so RomM stays reachable over plain HTTP from the building LAN. That's what Step 4 asked for. If you'd rather make it tailnet-only, change `80:8080` to `127.0.0.1:80:8080` and `docker compose up -d`; tailscale serve keeps working.

### Step 5: Load files, 13:01 MDT
- `~/roms` does not exist on claude-agent, so **nothing was imported and nothing was skipped**. No ROM/BIOS/firmware files were downloaded from anywhere.
- Permissions: `chmod -R u+rwX,go+rX /library/roms /library/bios`. RomM's container runs as root (uid 0 inside Docker = root in the CT = 100000 on pve3), same owner as /library, so it can read and write the library.
- Triggered a Quick scan via the API (`POST /api/tasks/scan {"type":"quick"}`, CSRF cookie + basic auth). Finished in under 1 s: 5 platforms found and identified (gb, gba, gbc, nds, psp), 0 ROMs, 0 firmware. The empty folders are registered in RomM.

### Step 6: HTTPS and PSP, 13:02 MDT
- RomM docs (EmulatorJS page, 5.4.0): PSP uses the ppsspp core, which needs SharedArrayBuffer, which needs a **secure (https) and cross-origin-isolated** page.
- RomM's bundled nginx already sends the isolation headers on the player routes only (`/etc/nginx/conf.d/default.conf` in the romm container: `map $request_uri` for `^/rom/.*/(ejs|jsdos)` and `^/console/rom/N/play`). Verified: `curl -I http://127.0.0.1/rom/1/ejs` returns `Cross-Origin-Embedder-Policy: require-corp` and `Cross-Origin-Opener-Policy: same-origin`. The `/` page doesn't send them, which is upstream's intent.
- `tailscale serve` is a transparent proxy and passes these headers through, so HTTPS from Tailscale is the only missing piece. No extra reverse proxy needed.
- Tailnet ACL (`~/tailscale-acl.hujson`): no change needed. macbook/iphone/desktop have `*:*`, so they reach `romm:443`; romm gets no outbound grants (default deny), which is right for it.
- `tailscale serve` can't be preconfigured while logged out ("No serve config"), so it waits on the login.
- 13:07 MDT: Tailscale login completed (romm = **<romm-tailnet-ip>**, key expiry 2027-04-13). Ran `tailscale serve --bg --https=443 http://127.0.0.1:80`. Status: `https://romm.tailnet-name.ts.net (tailnet only)`. Funnel is **not** enabled, so nothing is on the public internet.
- Verified from claude-agent over the tailnet: `/` 200 over HTTP/2, Let's Encrypt cert (valid to 2027-01-13), `/api/heartbeat` 200, `/rom/1/ejs` returns `cross-origin-embedder-policy: require-corp` + `cross-origin-opener-policy: same-origin` over HTTPS.
- Emulator cores bundled in the full image and served over HTTPS (200): `gambatte` (GB/GBC) 967 KB, `melonds` (DS) 1.2 MB, `ppsspp-thread` (PSP) 4.6 MB, plus `mgba` (GBA) and `desmume` present. Same-origin assets don't need CORP headers under `require-corp`.
- **Not tested: actual GB/DS/PSP game launches.** There are no games in the library (no ~/roms), and I didn't download any. Everything a launch needs (HTTPS, isolation headers, cores) is checked above. Do one real launch per platform after you add files.
- Final health check on pve3: all other guests still running (100, 101, 200, 201, VM 300). Thin pool data 34.79% (was 31.24%). Host RAM 4.7 GiB available.

---

# Final report

## At a glance
| Item | Value |
|---|---|
| Node / CTID | pve3 / **106** (`romm`), unprivileged Debian 12, onboot |
| LAN | **http://<lan-ip>:80** (DHCP; building LAN, plain HTTP; PSP won't run here) |
| Tailnet HTTPS | **https://romm.tailnet-name.ts.net** (tailnet only, use this one) |
| Tailscale IP | <romm-tailnet-ip> |
| RomM version | 5.4.0 (`rommapp/romm:latest`), MariaDB `latest` |
| Library | `/library` in CT 106 (58G volume `local-lvm:vm-106-disk-1`) |

## First login / admin
1. Open https://romm.tailnet-name.ts.net from the MacBook/iPhone/desktop (they're allowed by the `*:*` ACL rule).
2. The setup wizard is already done. I created admin **`spencer`** so nobody on the apartment LAN could claim it first. Get the password with:
   `ssh root@pve3 "pct exec 106 -- cat /opt/romm/admin-initial-credentials.txt"`
3. Log in, change the password (profile/avatar menu > Account), then delete the file:
   `ssh root@pve3 "pct exec 106 -- rm /opt/romm/admin-initial-credentials.txt"`
4. Optional: add metadata provider keys (below), then run an "Unmatched" scan.

## Secrets
- `/opt/romm/.env` in CT 106 (root:root, 600): ROMM_AUTH_SECRET_KEY, DB_PASSWD (romm-user), MARIADB_ROOT_PASSWORD.
- `/opt/romm/admin-initial-credentials.txt` (root:root, 600): initial admin password. Delete after changing it.
- **Metadata keys:** fill `SCREENSCRAPER_USER/PASSWORD`, `RETROACHIEVEMENTS_API_KEY`, `STEAMGRIDDB_API_KEY`, `IGDB_CLIENT_ID/SECRET` in `/opt/romm/.env`, then `cd /opt/romm && docker compose up -d`. How to get each: https://docs.romm.app/latest/getting-started/metadata-providers/ . Hasheous and libretro matching already work with no key.
- The CT and its .env are inside vzdump backups once you add 106 to a job (see Backup). Treat those archives at the same trust level as vaultwarden's.

## Imported files
- None. `~/roms` didn't exist on claude-agent. Nothing imported, nothing skipped, nothing downloaded.
- RomM shows the 5 empty platforms: gb, gbc, gba, nds, psp.

## Adding ROMs and BIOS later
Layout (RomM "Structure A"):
```
/library/roms/gb/     *.gb
/library/roms/gbc/    *.gbc
/library/roms/gba/    *.gba
/library/roms/nds/    *.nds
/library/roms/psp/    *.iso, *.cso, *.pbp (multi-file game = one subfolder)
/library/bios/nds/    bios7.bin, bios9.bin, firmware.bin   (exact names)
```
CT 106 runs sshd with key-only root login, seeded with the same keys as pve3 (MacBook + sandbox). Copy over the LAN or via pve3:
```
# from the MacBook (tailnet ACL allows *:*; SSH over the tailnet works because romm runs plain sshd)
rsync -av --progress ./gba/ root@romm:/library/roms/gba/
rsync -av ./bios7.bin ./bios9.bin ./firmware.bin root@romm:/library/bios/nds/
# fallback through pve3, if direct SSH to romm ever fails
scp game.gba root@pve3:/tmp/ && ssh root@pve3 "pct push 106 /tmp/game.gba /library/roms/gba/game.gba && rm /tmp/game.gba"
```
Rescan: the filesystem watcher picks up new files about 5 minutes after the copy finishes, and a nightly Quick scan runs at 03:00. To scan right away: RomM UI > Scan (top bar / Library management) > Quick, or for new folders "New Platforms". After adding metadata keys run "Unmatched".
Files copied as root are readable by RomM (it runs as root in Docker). If you copy as another user: `chmod -R u+rwX,go+rX /library/roms /library/bios`.

## Update RomM
```
ssh root@pve3 "pct exec 106 -- bash -c 'cd /opt/romm && docker compose pull && docker compose up -d && docker image prune -f'"
```
Read the release notes first (https://github.com/rommapp/romm/releases) and take a DB dump before major versions. Debian + Docker + Tailscale packages update with `apt update && apt full-upgrade` inside the CT.

## Back up
- **DB (consistent dump, inside CT 106):**
  ```
  cd /opt/romm && set -a && . ./.env && set +a
  docker exec romm-db mariadb-dump --user=romm-user --password="$DB_PASSWD" --single-transaction --databases romm > /opt/romm/romm-db-$(date +%F).sql
  ```
- **State:** `/opt/romm/{assets,config,resources}` + `.env` + `docker-compose.yml` (critical: assets = saves/states, config).
- **Library:** `/library` (ROMs + BIOS).
- **Easiest whole-thing backup:** add 106 to the existing pve3 job: Datacenter > Backup > `offsite-pve2-pve3-to-proxmox` > add 106 (or `pvesh set /cluster/backup/offsite-pve2-pve3-to-proxmox --vmid 100,101,104,106,200,201,203,300,400`). mp0 has `backup=1`, so the library is included. For a perfectly consistent DB inside a snapshot backup, run the dump above from a cron in the CT before 02:00. **I did not change the backup job**; it covers other guests and the call is yours (58G of ROMs adds to Storage_2 usage).

## Every change, and how to undo it
**On pve3**
| Change | Undo |
|---|---|
| Downloaded template `local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst` (124 MB) | `pveam remove local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst` |
| Created CT 106 (config `/etc/pve/lxc/106.conf`, incl. `dev0: /dev/net/tun`, onboot=1) | `pct stop 106 && pct destroy 106 --purge` (deletes both volumes and all data) |
| Thin volumes `pve/vm-106-disk-0` (16G rootfs), `pve/vm-106-disk-1` (58G /library) | removed by `pct destroy` above |
| Nothing else on pve3: no host firewall, network, storage.cfg, or backup job changes | |

**Inside CT 106**
| Change | Undo |
|---|---|
| apt full-upgrade; installed curl, ca-certificates, gnupg; timezone America/Denver | n/a (base system) |
| Tailscale repo + package, tailscaled enabled, logged in as `romm` | `tailscale logout; apt purge tailscale; rm /etc/apt/sources.list.d/tailscale.list`; remove the machine in the Tailscale admin console |
| `tailscale serve --https=443 http://127.0.0.1:80` | `tailscale serve --https=443 off` |
| Docker repo (`/etc/apt/keyrings/docker.asc`, `/etc/apt/sources.list.d/docker.list`) + docker-ce, compose plugin, buildx, containerd | `apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; rm -r /var/lib/docker /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc` |
| `/opt/romm/` (compose, .env, admin creds, mysql, assets, config, resources, redis-data) | `cd /opt/romm && docker compose down && rm -rf /opt/romm` |
| RomM stack (containers romm, romm-db; images rommapp/romm, mariadb) | `docker compose down` / `docker image rm rommapp/romm mariadb` |
| RomM admin user `spencer` (DB row) | delete in RomM UI > Administration > Users, or drop the DB |
| `/library/roms/{gb,gbc,gba,nds,psp}`, `/library/bios/nds`, `chmod go+rX` | `rm -r /library/roms /library/bios` (only when empty) |
| `/root/ts-up.log` | `rm /root/ts-up.log` |

**On claude-agent:** `~/romm/SETUP_LOG.md` (this file) and a memory note. Nothing else.

## Loose ends / suggestions
- Actual game launches (GB, DS, PSP) are untested because there are no games. Try one per platform after copying files. DS needs the three BIOS files only for some games/cores; melonDS works without them for most.
- Not added to vzdump jobs, Uptime Kuma, Wazuh, or the ACL `hosts` map (it works without it because your devices have `*:*`).
- Port 80 is open to the apartment LAN over plain HTTP. If you only use the tailnet URL, bind it to `127.0.0.1:80:8080`.
- Tailscale node key expires 2027-04-13; disable expiry in the admin console if you want.
- local-lvm thin pool: 34.8% used, but provisioned well above its size. Keep an eye on it as ROMs land.
