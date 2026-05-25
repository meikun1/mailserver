# DNS для veximail.space

Подставь `SERVER_IP` — публичный IPv4 сервера. Все записи в зоне `veximail.space`.

| Тип   | Имя                | Значение                                  | TTL  |
|-------|--------------------|-------------------------------------------|------|
| A     | `mail`             | `SERVER_IP`                               | 300  |
| MX    | `@`                | `10 mail.veximail.space.`                 | 300  |
| TXT   | `@`                | `v=spf1 a:mail.veximail.space ~all`       | 300  |
| TXT   | `_dmarc`           | `v=DMARC1; p=none; rua=mailto:postmaster@veximail.space` | 300  |

Опционально (если на этот IP не висит ничего стороннего):

| Тип   | Имя                | Значение                                  | TTL  |
|-------|--------------------|-------------------------------------------|------|
| A     | `@`                | `SERVER_IP`                               | 300  |

На старте держи TTL = 300. После того как всё проверишь — подними до 3600.

## PTR (reverse DNS)

Настраивается **в панели хостера**, не в зоне домена. Найди раздел вида
«Reverse DNS», «rDNS», «PTR» для IP сервера и задай:

```
SERVER_IP  →  mail.veximail.space
```

Проверка с любой машины:

```
dig -x SERVER_IP +short
```

Должно вернуть `mail.veximail.space.`. Согласованность обязательна:

```
PTR (rDNS)              = mail.veximail.space
myhostname (postfix)    = mail.veximail.space
SMTP banner             = mail.veximail.space ESMTP
A mail.veximail.space   = SERVER_IP
```

## Проверка снаружи

```
dig MX veximail.space +short
dig A mail.veximail.space +short
dig TXT veximail.space +short
dig -x SERVER_IP +short
```
