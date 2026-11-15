#!/bin/bash
# Wazuh manager: decoder + rules for Authentik login events (written 2026-11-13).
# Run on wazuh as:  sudo bash ~/wazuh-authentik-rules.sh
# Alerts at level 10+ go to Discord (custom-discord integration).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
OSSEC=/var/ossec
DEC=$OSSEC/etc/decoders/local_decoder.xml
RUL=$OSSEC/etc/rules/local_rules.xml
if grep -q 'decoder name="authentik"' "$DEC" 2>/dev/null; then echo "Authentik decoder already present, stopping."; exit 1; fi

TS=$(date +%Y%m%d-%H%M%S)
cp -p "$DEC" "$DEC.bak-$TS"; cp -p "$RUL" "$RUL.bak-$TS"
restore() { cp -p "$DEC.bak-$TS" "$DEC"; cp -p "$RUL.bak-$TS" "$RUL"; echo "Restored the original files. Nothing is live."; }

cat >> "$DEC" <<'EOF'

<!-- Authentik (LXC 205 `auth`): Docker logs to journald tagged with the container name. -->
<decoder name="authentik">
  <program_name>^authentik-server-1$|^authentik-worker-1$</program_name>
</decoder>
<decoder name="authentik-json">
  <parent>authentik</parent>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>
EOF

cat >> "$RUL" <<'EOF'

<!-- Authentik SSO events (2026-11-13). Level 10+ reaches Discord. -->
<group name="authentik,authentication,">
  <rule id="100620" level="0">
    <decoded_as>authentik</decoded_as>
    <description>Authentik log line</description>
  </rule>

  <rule id="100621" level="5">
    <if_sid>100620</if_sid>
    <field name="action">^login_failed$</field>
    <description>Authentik: failed login for '$(context.username)' from $(client_ip)</description>
    <group>authentication_failed,</group>
  </rule>

  <rule id="100622" level="10" frequency="5" timeframe="300">
    <if_matched_sid>100621</if_matched_sid>
    <same_field>client_ip</same_field>
    <description>Authentik: 5 failed logins in 5 minutes from $(client_ip) (last tried '$(context.username)')</description>
    <group>authentication_failures,</group>
  </rule>

  <rule id="100623" level="3">
    <if_sid>100620</if_sid>
    <field name="action">^login$</field>
    <description>Authentik: $(user.username) logged in from $(client_ip)</description>
    <group>authentication_success,</group>
  </rule>

  <!-- Spencer's macbook, iphone, desktop. Update if a device's tailnet IP changes. -->
  <rule id="100624" level="10">
    <if_sid>100623</if_sid>
    <field name="client_ip" type="pcre2" negate="yes">^(100\.114\.99\.94|100\.78\.203\.90|100\.95\.189\.9)$</field>
    <description>Authentik: $(user.username) logged in from an unknown device ($(client_ip))</description>
  </rule>

  <rule id="100625" level="10">
    <if_sid>100620</if_sid>
    <field name="action">^password_set$</field>
    <description>Authentik: password changed for $(user.username)</description>
  </rule>

  <rule id="100626" level="10">
    <if_sid>100620</if_sid>
    <field name="action">^suspicious_request$|^impersonation_started$</field>
    <description>Authentik: $(action) by $(user.username) from $(client_ip)</description>
  </rule>
</group>
EOF

echo "== Config check"
if ! $OSSEC/bin/wazuh-analysisd -t 2>&1 | tail -3; then restore; exit 1; fi
$OSSEC/bin/wazuh-analysisd -t >/dev/null 2>&1 || { restore; exit 1; }

echo "== Test against real Authentik log lines"
P='Nov 13 18:52:28 auth authentik-server-1[181256]: '
FAIL='{"action": "login_failed", "auth_via": "unauthenticated", "client_ip": "<sandbox-tailnet-ip>", "context": {"username": "wazuh-test-nosuchuser"}, "event": "Created Event", "logger": "authentik.events.models", "user": {"username": "wazuh-test-nosuchuser"}}'
OK_KNOWN='{"action": "login", "client_ip": "<macbook-tailnet-ip>", "event": "Created Event", "logger": "authentik.events.models", "user": {"pk": 4, "username": "akadmin"}}'
OK_UNKNOWN='{"action": "login", "client_ip": "<lan-ip>", "event": "Created Event", "logger": "authentik.events.models", "user": {"pk": 4, "username": "akadmin"}}'
OUT=$(printf '%s\n' "$P$FAIL" "$P$OK_KNOWN" "$P$OK_UNKNOWN" | timeout 30 $OSSEC/bin/wazuh-logtest 2>&1 || true)
echo "$OUT" | grep -E "id: '1006|description:" | sed 's/^\s*/   /'
for want in 100621 100623 100624; do
  echo "$OUT" | grep -q "id: '$want'" || { echo "Rule $want did not match its test line."; restore; exit 1; }
done
echo "   all three test lines matched the expected rules"

echo "== Restart the manager"
systemctl restart wazuh-manager
sleep 10
systemctl is-active wazuh-manager
echo
echo "Done. Backups: $DEC.bak-$TS and $RUL.bak-$TS"
echo "Undo: sudo cp -p $DEC.bak-$TS $DEC && sudo cp -p $RUL.bak-$TS $RUL && sudo systemctl restart wazuh-manager"
