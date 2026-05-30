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

HASH="{SHA512-CRYPT}$(openssl passwd -6 -stdin <<< "$CATCHALL_PASSWORD")"
umask 077
printf "%s:%s::::::\n" "$CATCHALL_ADDR" "$HASH" > /etc/dovecot/users
chown root:dovecot /etc/dovecot/users
chmod 0640 /etc/dovecot/users

systemctl enable postfix dovecot
systemctl restart postfix dovecot
systemctl enable --now certbot.timer || true

newaliases || true

echo
echo "deployed."
echo "  hostname:  ${HOSTNAME_FQDN}"
echo "  domain:    ${DOMAIN}"
echo "  catchall:  ${CATCHALL_ADDR}"
echo "  maildir:   /var/mail/vhosts/${DOMAIN}/${CATCHALL_USER}/Maildir"
echo "  imap:      ${HOSTNAME_FQDN}:993 (TLS), user ${CATCHALL_ADDR}"
echo "  pop3:      ${HOSTNAME_FQDN}:995 (TLS), user ${CATCHALL_ADDR}"
echo
echo "next: set DNS (see DNS.md), set PTR at hoster, then run CHECKLIST.md."
