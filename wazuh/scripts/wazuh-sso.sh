#!/bin/bash
# Wazuh dashboard: add "Log in with Authentik" (OpenID Connect) next to the normal login.
# Run on wazuh as:  sudo bash ~/wazuh-sso.sh
# Written 2026-11-13. Everything it changes is backed up to /root/wazuh-sso-backup-<time>/.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

SECRET_FILE=/home/s9302/.wazuh-oidc-secret
ISSUER=https://auth.tailnet-name.ts.net/application/o/wazuh/
DISCOVERY=${ISSUER}.well-known/openid-configuration
ADMIN_GROUP="authentik Admins"
DASH_YML=/etc/wazuh-dashboard/opensearch_dashboards.yml
WAZUH_YML=/usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml
SEC_TOOLS=/usr/share/wazuh-indexer/plugins/opensearch-security/tools
CERTS=/etc/wazuh-indexer/certs
export JAVA_HOME=/usr/share/wazuh-indexer/jdk

[ -s "$SECRET_FILE" ] || { echo "missing $SECRET_FILE"; exit 1; }
if grep -q '^opensearch_security.openid' "$DASH_YML"; then echo "OpenID already configured in $DASH_YML, stopping."; exit 1; fi

echo "== 1. Can the indexer reach Authentik? (needs the tailnet ACL rule wazuh -> auth:443)"
curl -fsS -o /dev/null --max-time 8 "$DISCOVERY" || { echo "Cannot reach $DISCOVERY. ACL not applied yet? Nothing was changed."; exit 1; }
echo "   ok"

BK=/root/wazuh-sso-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK/live-security"
cp -p "$DASH_YML" "$WAZUH_YML" "$BK/"

# Which address the indexer listens on (securityadmin must use it).
HOST=$(awk -F': *' '/^network.host/ {gsub(/"/,"",$2); print $2}' /etc/wazuh-indexer/opensearch.yml)
[ -z "$HOST" ] || [ "$HOST" = 0.0.0.0 ] && HOST=127.0.0.1
SA=("$SEC_TOOLS/securityadmin.sh" -icl -nhnv -h "$HOST" -cacert "$CERTS/root-ca.pem" -cert "$CERTS/admin.pem" -key "$CERTS/admin-key.pem")

echo "== 2. Export the security config the indexer is actually using"
"${SA[@]}" -backup "$BK/live-security" >/dev/null
ls "$BK/live-security"/config.yml "$BK/live-security"/roles_mapping.yml >/dev/null
mkdir -p "$BK/new" && cp "$BK/live-security"/config.yml "$BK/live-security"/roles_mapping.yml "$BK/new/"

echo "== 3. Add the OpenID auth domain and map '$ADMIN_GROUP' to all_access"
python3 - "$BK/new" "$DISCOVERY" "$ADMIN_GROUP" <<'PY'
import sys, yaml
d, disc, group = sys.argv[1:]
c = yaml.safe_load(open(f"{d}/config.yml"))
authc = c["config"]["dynamic"]["authc"]
# Basic auth must not send a browser password challenge, or the SSO button never gets a chance.
authc["basic_internal_auth_domain"]["http_authenticator"]["challenge"] = False
authc["openid_auth_domain"] = {
    "description": "Authentik SSO",
    "http_enabled": True, "transport_enabled": True, "order": 1,
    "http_authenticator": {"type": "openid", "challenge": False, "config": {
        "subject_key": "preferred_username", "roles_key": "groups", "openid_connect_url": disc}},
    "authentication_backend": {"type": "noop"},
}
yaml.safe_dump(c, open(f"{d}/config.yml", "w"), sort_keys=False)
r = yaml.safe_load(open(f"{d}/roles_mapping.yml"))
br = r.setdefault("all_access", {}).setdefault("backend_roles", [])
if group not in br: br.append(group)
yaml.safe_dump(r, open(f"{d}/roles_mapping.yml", "w"), sort_keys=False)
print("   edited")
PY

echo "== 4. Upload the two changed files to the indexer"
"${SA[@]}" -f "$BK/new/config.yml" -t config | tail -1
"${SA[@]}" -f "$BK/new/roles_mapping.yml" -t rolesmapping | tail -1

echo "== 5. Dashboard settings"
cat >> "$DASH_YML" <<EOF

# Authentik SSO (2026-11-13). Normal username/password login still works.
opensearch_security.auth.multiple_auth_enabled: true
opensearch_security.auth.type: ["basicauth", "openid"]
opensearch_security.openid.connect_url: "$DISCOVERY"
opensearch_security.openid.client_id: "wazuh"
opensearch_security.openid.client_secret: "$(cat "$SECRET_FILE")"
opensearch_security.openid.scope: "openid profile email"
opensearch_security.openid.base_redirect_url: "https://wazuh.tailnet-name.ts.net"
opensearch_security.openid.logout_url: "${ISSUER}end-session/"
opensearch_security.ui.openid.login.buttonname: "Log in with Authentik"
EOF
# SSO users aren't Wazuh API users, so the app must not try to run API calls "as" them.
sed -i 's/^\(\s*run_as:\s*\)true/\1false/' "$WAZUH_YML"
grep -n 'run_as' "$WAZUH_YML" || true

echo "== 6. Restart the dashboard"
systemctl restart wazuh-dashboard
for i in $(seq 60); do curl -sk -o /dev/null https://127.0.0.1/ && break; sleep 3; done
systemctl is-active wazuh-dashboard
rm -f "$SECRET_FILE"

cat <<EOF

Done. Open https://wazuh.tailnet-name.ts.net and use "Log in with Authentik".
Backups: $BK
To undo:
  sudo cp -p $BK/opensearch_dashboards.yml $DASH_YML
  sudo cp -p $BK/wazuh.yml $WAZUH_YML
  sudo JAVA_HOME=$JAVA_HOME ${SA[*]} -f $BK/live-security/config.yml -t config
  sudo JAVA_HOME=$JAVA_HOME ${SA[*]} -f $BK/live-security/roles_mapping.yml -t rolesmapping
  sudo systemctl restart wazuh-dashboard
EOF
