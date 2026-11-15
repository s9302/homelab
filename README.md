# homelab

Config and scripts for my 3-node Proxmox cluster (proxmox, pve2, pve3). These are copies of the files that actually run on the machines, pulled into one place so they have history.

Secrets are not in here. Anything that was a password, token, client secret or webhook URL is replaced with `REDACTED`, and `.env` files were never copied. The real values live on the hosts, in root-only files.

## Layout

| Path | What it is |
|---|---|
| `tailscale/acl.hujson` | Tailscale ACL policy (least-privilege, with a `tests` block). History goes back to 2026-09-30. |
| `cluster/` | `/etc/pve`: guest configs, backup jobs (`jobs.cfg`), storage, SDN vnets (`lab`, `llm`), Authentik realm, notifications |
| `nodes/<node>/` | Per-node files at their real paths: `node-auto-update` + timer, `wazuh-wait-tailscale`, iptables rules, `/etc/network/interfaces`, NFS exports, `llm-sandbox` (pve2), `lab-status` (pve3), `site-repo-snapshot` (proxmox) |
| `services/<name>/` | Per-service files at their real paths: compose files, systemd units, Caddyfile, cloudflared configs, Forgejo `app.ini`, Pi-hole, Prometheus + Grafana alerting |
| `services/authentik/blueprint/` | Authentik config exported with `ak export_blueprint`: 8 OIDC providers/apps, flows, stages, MFA policy, custom scope mappings, groups. Client secrets redacted; users, passkeys, recovery codes, tokens and certificate keys removed. |
| `services/llm-router/` | VM 410: nftables, Squid + the `llm-allowed-hosts` allowlist, sysctl. This is what isolates the LLM sandbox. |
| `services/nextcloud/` | The Alpine host: periodic jobs (cron, apk-upgrade, Tailscale cert renewal), syslog forward to Wazuh, nginx, fail2ban, firewall, sshd |
| `authentik/` | `mkprov.sh` / `mkprov.py`, which create an OIDC provider + app in Authentik |
| `wazuh/manager/` | Wazuh manager config at its real path: `ossec.conf`, custom rules (`local_rules.xml`), decoders, shared agent config |
| `wazuh/scripts/` | Wazuh dashboard SSO setup and the Authentik login-alert rules/decoder |
| `docs/` | Setup logs for RomM and the xemu VM |

## Applying changes

Nothing deploys from this repo automatically. Edit the file on the host, then copy it back here and commit (or the reverse). The ACL is applied through the Tailscale API: fetch the live policy with its etag, edit, `POST .../acl/validate`, then `POST .../acl` with `If-Match`.
