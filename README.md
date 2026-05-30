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

Скрипт спросит пароль для catch-all-ящика интерактивно (вводится
скрыто, в argv и в shell history не попадает). Остальные параметры
не секретные, их можно прокинуть через переменные окружения:

```
DOMAIN=veximail.space \
HOSTNAME_FQDN=mail.veximail.space \
ADMIN_EMAIL=admin@veximail.space \
./install.sh
```

**Не передавай пароль через `CATCHALL_PASSWORD=... ./install.sh`** —
он попадёт в `~/.bash_history`, в `ps eww` родительского shell и в
`/proc/<pid>/environ`. Только интерактивный prompt.

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
openssl passwd -6
# программа дважды спросит пароль, выведет хеш вида $6$salt$hash
```

Открой `/etc/dovecot/users`, замени хеш в существующей строке так,
чтобы получилось:

```
catchall@veximail.space:{SHA512-CRYPT}$6$salt$hash::::::
```

Применить:

```
systemctl reload dovecot
```

Старый вариант `doveadm pw -p 'пароль'` не используем: пароль на
время выполнения виден в argv через `ps`. `openssl passwd` читает
пароль с tty и в argv не светит.
