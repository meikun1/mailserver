# Чеклист проверки и troubleshooting

## 1. Сервисы и порты

```
systemctl status postfix dovecot --no-pager
ss -tlnp | grep -E ':(25|143|993)\b'
```

Ожидаем: оба `active (running)`, на 25 слушает `master` (postfix),
на 143/993 — `dovecot`. Если 25 слушает только `127.0.0.1` — в
`main.cf` сломан `inet_interfaces = all`.

## 2. Брандмауэр

```
ufw status
nmap -p25,143,993 mail.veximail.space          # с любой внешней машины
```

Если `nmap` показывает `filtered` — порт зарезан в `ufw` или у хостера
в security group / network ACL.

## 3. SMTP-баннер должен прилетать мгновенно

С внешней машины:

```
time sh -c 'exec 3<>/dev/tcp/mail.veximail.space/25; head -1 <&3'
```

Ожидаем `220 mail.veximail.space ESMTP` за **< 1 с**. Если 5–15 с —
смотри пункт 9.

## 4. DNS на самом сервере отвечает быстро

```
time dig +short google.com
time dig +short -x 8.8.8.8
resolvectl status | sed -n '/Global/,/Link/p'
```

`DNS Servers` должен включать `1.1.1.1` и/или `8.8.8.8`. Все запросы
< 100 мс.

## 5. Внешний MX-резолвинг

```
dig MX veximail.space +short
dig A  mail.veximail.space +short
dig -x SERVER_IP +short
```

См. `DNS.md` — три верхние записи должны быть согласованы.

## 6. Прогон письма извне (golden path)

С любого внешнего ящика (gmail, например) отправь на
`anything-random@veximail.space`. Параллельно на сервере:

```
tail -f /var/log/mail.log
```

В логе должна появиться цепочка `connect from … → … from=<…> →
to=<catchall@veximail.space>, … status=sent (delivered via lmtp)`.

Файл письма:

```
ls -la /var/mail/vhosts/veximail.space/catchall/Maildir/new/
```

## 7. IMAP

```
openssl s_client -connect mail.veximail.space:993 -quiet
* OK
a login catchall@veximail.space ПАРОЛЬ
a list "" "*"
a select INBOX
a fetch 1 (body[header])
a logout
```

## 8. Место на диске

```
df -h /var/mail
du -sh /var/mail/vhosts/veximail.space/catchall/Maildir
```

Поставь cron-алерт на > 80% — catch-all жрёт диск незаметно.

---

# Troubleshooting

## «Письмо отправил, но в `/var/log/mail.log` пусто»

Письмо не доехало до 25 порта. Причины по убыванию вероятности:

1. **Медленный SMTP-баннер.** Отправитель рвёт коннект по таймауту
   до отправки `MAIL FROM`. Проверка:
   ```
   time sh -c 'exec 3<>/dev/tcp/mail.veximail.space/25; head -1 <&3'
   ```
   Если > 2 с — фикси DNS (пункт 9).
2. **Порт 25 закрыт снаружи.** `nmap -p25 mail.veximail.space` с
   внешней машины. Если `filtered` — `ufw`/security group.
3. **MX указывает не туда.** `dig MX veximail.space +short` →
   `10 mail.veximail.space.`, и `dig A mail.veximail.space` →
   правильный IP.
4. **PTR не настроен** — gmail и крупные провайдеры режут такие
   входящие *молча*, в логах сервера действительно пусто.
   Проверка: `dig -x SERVER_IP +short`.

## Задержка SMTP-баннера (5–15 с)

Postfix синхронно делает обратный DNS-запрос на коннекте, а резолвер
тупит. Лечение:

1. Резолвер. `/etc/systemd/resolved.conf.d/99-mail.conf` должен
   содержать `DNS=1.1.1.1 8.8.8.8`. После правки:
   `systemctl restart systemd-resolved && resolvectl flush-caches`.
2. Никаких `reject_unknown_client_hostname` /
   `reject_unknown_reverse_client_hostname` в `smtpd_*_restrictions`.
   Проверка: `postconf -n | grep -E 'smtpd_(client|recipient|helo|sender)_restrictions'`.
3. `postscreen` выключен (по умолчанию так и есть).

## `relay access denied` / 554 5.7.1

Постфикс думает, что письмо не для нас. Проверь:

```
postconf -n | grep -E 'virtual_mailbox_domains|mydestination'
postmap -q '@veximail.space' hash:/etc/postfix/virtual
postmap -q 'catchall@veximail.space' hash:/etc/postfix/vmailbox
```

Первое — должно содержать `veximail.space`. Вторые две —
непустые ответы. Если карты пустые: `postmap /etc/postfix/virtual`
и `postmap /etc/postfix/vmailbox`, потом `systemctl reload postfix`.

## `User unknown in virtual mailbox table`

`virtual` или `vmailbox` не подхватились или не отрендерены.

```
cat /etc/postfix/virtual
cat /etc/postfix/vmailbox
postmap -q 'foo@veximail.space' hash:/etc/postfix/virtual
```

Catch-all строка должна выглядеть так:
`@veximail.space catchall@veximail.space`.

## LMTP не доставляет (`status=deferred`, `Connection refused`)

Dovecot LMTP-сокет не на месте.

```
ls -la /var/spool/postfix/private/dovecot-lmtp
systemctl status dovecot
journalctl -u dovecot -n 50 --no-pager
```

Сокет должен существовать, `mode 0600`, `user/group postfix`.
Если нет — `systemctl restart dovecot`.

## TLS-сертификат не валиден / expired

```
openssl s_client -connect mail.veximail.space:993 -servername mail.veximail.space < /dev/null 2>/dev/null | openssl x509 -noout -dates
certbot certificates
systemctl list-timers | grep certbot
```

Ручное продление: `certbot renew --force-renewal && systemctl reload postfix dovecot`.

## Письма доходят, но Gmail кладёт в спам

1. PTR (см. `DNS.md`).
2. SPF: `dig TXT veximail.space +short | grep spf1`.
3. DMARC: `dig TXT _dmarc.veximail.space +short`.
4. Низкий "репутационный" возраст IP. Это решается временем,
   не конфигом.

## Диагностические one-liners

```
postconf -n                              # эффективный main.cf
postqueue -p                             # очередь
postsuper -d ALL                         # снести очередь (осторожно)
doveadm user catchall@veximail.space     # проверка userdb
doveconf -n                              # эффективный dovecot.conf
journalctl -u postfix -n 100 --no-pager
journalctl -u dovecot -n 100 --no-pager
```
