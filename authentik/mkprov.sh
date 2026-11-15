#!/bin/bash
# run on proxmox: mkprov.sh NAME SLUG REDIR LAUNCH  -> secret at /root/.oidc-<slug> (600)
set -e; umask 077
pct push 205 /root/mkprov.py /tmp/mkprov.py
pct exec 205 -- bash -c "cd /opt/authentik && docker compose cp /tmp/mkprov.py worker:/tmp/mkprov.py >/dev/null 2>&1 && docker compose exec -T -e P_NAME='$1' -e P_SLUG='$2' -e P_REDIR='$3' -e P_LAUNCH='$4' worker ak shell -c 'exec(open(\"/tmp/mkprov.py\").read())' 2>&1 | grep -E '^provider|Error'"
pct exec 205 -- bash -c "cd /opt/authentik && docker compose exec -T worker sh -c 'cat /tmp/$2-secret; rm /tmp/$2-secret /tmp/mkprov.py'" > /root/.oidc-$2
test -s /root/.oidc-$2 && echo "secret saved for $2"
