#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must run as root" >&2
  exit 1
fi

DOMAIN="${DOMAIN:-veximail.space}"
HOSTNAME_FQDN="${HOSTNAME_FQDN:-mail.${DOMAIN}}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
CATCHALL_USER="${CATCHALL_USER:-catchall}"
CATCHALL_ADDR="${CATCHALL_USER}@${DOMAIN}"

if [[ -z "${CATCHALL_PASSWORD:-}" ]]; then
  read -rsp "Password for ${CATCHALL_ADDR}: " CATCHALL_PASSWORD
  echo
fi

if [[ -z "${CATCHALL_PASSWORD}" ]]; then
  echo "empty password" >&2
  exit 1
fi

TG_ENV_FILE="/etc/tgbot/env"
if [[ -z "${TG_BOT_TOKEN:-}" && -f "$TG_ENV_FILE" ]]; then
  TG_BOT_TOKEN="$(awk -F= '/^TG_BOT_TOKEN=/{sub(/^TG_BOT_TOKEN=/,""); print; exit}' "$TG_ENV_FILE" || true)"
fi
if [[ -z "${TG_CHAT_ID:-}" && -f "$TG_ENV_FILE" ]]; then
  TG_CHAT_ID="$(awk -F= '/^TG_CHAT_ID=/{sub(/^TG_CHAT_ID=/,""); print; exit}' "$TG_ENV_FILE" || true)"
fi
if [[ -z "${TG_BOT_TOKEN:-}" ]]; then
  read -rsp "Telegram bot token (from @BotFather, leave empty to skip): " TG_BOT_TOKEN
  echo
fi
if [[ -n "${TG_BOT_TOKEN:-}" && -z "${TG_CHAT_ID:-}" ]]; then
  read -rp "Telegram chat id (numeric, leave empty to skip): " TG_CHAT_ID
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hostnamectl set-hostname "$HOSTNAME_FQDN"
if ! grep -qE "^[0-9.]+\s+${HOSTNAME_FQDN}\b" /etc/hosts; then
  printf "127.0.1.1 %s %s\n" "$HOSTNAME_FQDN" "$(echo "$HOSTNAME_FQDN" | cut -d. -f1)" >> /etc/hosts
fi

export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "postfix postfix/mailname string ${HOSTNAME_FQDN}"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
apt-get update
apt-get install -y \
  postfix postfix-pcre \
  dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd \
  certbot ufw ca-certificates mailutils dnsutils \
  python3

install -d -m 0755 /etc/systemd/resolved.conf.d
install -m 0644 "${SCRIPT_DIR}/systemd/resolved.conf" /etc/systemd/resolved.conf.d/99-mail.conf
systemctl restart systemd-resolved

ufw allow OpenSSH || ufw allow 22/tcp
ufw allow 25/tcp
ufw allow 80/tcp
ufw allow 143/tcp
ufw allow 993/tcp
ufw allow 110/tcp
ufw allow 995/tcp
ufw --force enable

systemctl stop postfix dovecot 2>/dev/null || true

if [[ ! -f "/etc/letsencrypt/live/${HOSTNAME_FQDN}/fullchain.pem" ]]; then
  certbot certonly --standalone --non-interactive --agree-tos \
    -m "$ADMIN_EMAIL" -d "$HOSTNAME_FQDN" --preferred-challenges http
fi

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh <<'HOOK'
#!/bin/sh
systemctl reload postfix 2>/dev/null || true
systemctl reload dovecot 2>/dev/null || true
systemctl restart tgbot   2>/dev/null || true
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh

getent group vmail >/dev/null || groupadd -g 5000 vmail
getent passwd vmail >/dev/null || useradd -u 5000 -g vmail -d /var/mail/vhosts -s /usr/sbin/nologin -M vmail
install -d -o vmail -g vmail -m 0770 /var/mail/vhosts
install -d -o vmail -g vmail -m 0770 "/var/mail/vhosts/${DOMAIN}"
install -d -o vmail -g vmail -m 0770 "/var/mail/vhosts/${DOMAIN}/${CATCHALL_USER}"
install -d -o vmail -g vmail -m 0770 "/var/mail/vhosts/${DOMAIN}/${CATCHALL_USER}/Maildir"

render() {
  sed -e "s|__DOMAIN__|${DOMAIN}|g" \
      -e "s|__HOSTNAME__|${HOSTNAME_FQDN}|g" \
      -e "s|__CATCHALL_ADDR__|${CATCHALL_ADDR}|g" \
      "$1"
}

render "${SCRIPT_DIR}/postfix/main.cf"  > /etc/postfix/main.cf
render "${SCRIPT_DIR}/postfix/virtual"  > /etc/postfix/virtual
render "${SCRIPT_DIR}/postfix/vmailbox" > /etc/postfix/vmailbox

postmap /etc/postfix/virtual
postmap /etc/postfix/vmailbox

install -d -m 0755 /etc/dovecot
render "${SCRIPT_DIR}/dovecot/dovecot.conf" > /etc/dovecot/dovecot.conf
rm -rf /etc/dovecot/conf.d

HASH="$(doveadm pw -s SHA512-CRYPT -p "$CATCHALL_PASSWORD")"
umask 077
printf "%s:%s::::::\n" "$CATCHALL_ADDR" "$HASH" > /etc/dovecot/users
chown root:dovecot /etc/dovecot/users
chmod 0640 /etc/dovecot/users

systemctl enable postfix dovecot
systemctl restart postfix dovecot
systemctl enable --now certbot.timer || true

getent group  tgbot >/dev/null || groupadd -r tgbot
getent passwd tgbot >/dev/null || useradd -r -g tgbot -d /var/lib/tgbot -s /usr/sbin/nologin -M tgbot
install -d -o tgbot -g tgbot -m 0700 /var/lib/tgbot
install -d -m 0750 /etc/tgbot

if [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]; then
  umask 077
  cat > "$TG_ENV_FILE" <<EOF
IMAP_HOST=${HOSTNAME_FQDN}
IMAP_USER=${CATCHALL_ADDR}
IMAP_PASS=${CATCHALL_PASSWORD}
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_CHAT_ID=${TG_CHAT_ID}
STATE_DIR=/var/lib/tgbot
POLL_INTERVAL=15
SEND_NO_CODE=0
EOF
  chown root:tgbot "$TG_ENV_FILE"
  chmod 0640 "$TG_ENV_FILE"
fi

install -m 0644 "${SCRIPT_DIR}/tgbot/tgbot.service" /etc/systemd/system/tgbot.service
systemctl daemon-reload

if [[ -f "$TG_ENV_FILE" ]]; then
  systemctl enable tgbot
  systemctl restart tgbot
  TGBOT_STATUS="enabled"
else
  systemctl disable tgbot 2>/dev/null || true
  TGBOT_STATUS="not configured (no TG_BOT_TOKEN/TG_CHAT_ID; rerun installer to enable)"
fi

newaliases || true

echo
echo "deployed."
echo "  hostname:  ${HOSTNAME_FQDN}"
echo "  domain:    ${DOMAIN}"
echo "  catchall:  ${CATCHALL_ADDR}"
echo "  maildir:   /var/mail/vhosts/${DOMAIN}/${CATCHALL_USER}/Maildir"
echo "  imap:      ${HOSTNAME_FQDN}:993 (TLS), user ${CATCHALL_ADDR}"
echo "  pop3:      ${HOSTNAME_FQDN}:995 (TLS), user ${CATCHALL_ADDR}"
echo "  tgbot:     ${TGBOT_STATUS}"
echo
echo "next: set DNS (see DNS.md), set PTR at hoster, then run CHECKLIST.md."
