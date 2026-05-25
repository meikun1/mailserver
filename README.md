# mailserver — catch-all для veximail.space

Postfix (MTA, приём 25) + Dovecot (LMTP-доставка, IMAP 143/993, maildir).
Только входящие. Любой адрес `*@veximail.space` → один общий ящик
`catchall@veximail.space`.

Стек: Ubuntu 24.04 LTS, Let's Encrypt, systemd-resolved.

## Развёртывание

На свежем сервере (root):

```
git clone <repo> /opt/mailserver && cd /opt/mailserver
chmod +x install.sh
./install.sh
```

Скрипт спросит только пароль для catch-all-ящика. Можно прокинуть
через переменные окружения:

```
DOMAIN=veximail.space \
HOSTNAME_FQDN=mail.veximail.space \
ADMIN_EMAIL=admin@veximail.space \
CATCHALL_PASSWORD='...' \
./install.sh
```

## Перед запуском

1. A-запись `mail.veximail.space → SERVER_IP` уже распространилась
   (`dig +short A mail.veximail.space` отвечает правильным IP).
2. На сервере открыт 80/tcp для ACME-челленджа certbot.
3. PTR `SERVER_IP → mail.veximail.space` настроен у хостера
   (можно и после, но без него gmail режет).

DNS — см. `DNS.md`. Проверка после установки — `CHECKLIST.md`.

## Где что лежит

```
/etc/postfix/main.cf            — конфиг MTA
/etc/postfix/virtual            — catch-all alias
/etc/postfix/vmailbox           — virtual mailbox map
/etc/dovecot/dovecot.conf       — конфиг IMAP/LMTP
/etc/dovecot/users              — passwd-file (SHA512-CRYPT)
/var/mail/vhosts/<domain>/<user>/Maildir/  — письма
/var/log/mail.log               — Postfix
/var/log/dovecot.log            — Dovecot
/etc/letsencrypt/live/mail.veximail.space/ — TLS-сертификат
```

## Доступ к почте

IMAP: `mail.veximail.space:993` (TLS), логин
`catchall@veximail.space`, пароль — заданный при установке.

## Смена пароля

```
doveadm pw -s SHA512-CRYPT -p 'новый-пароль'
# полученный хеш вставить в /etc/dovecot/users
systemctl reload dovecot
```
