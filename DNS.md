# DNS для veximail.space

Сервер: `178.16.55.219`. Все записи в зоне `veximail.space`.

| Тип   | Имя                | Значение                                  | TTL  |
|-------|--------------------|-------------------------------------------|------|
| A     | `mail`             | `178.16.55.219`                          | 300  |
| MX    | `@`                | `10 mail.veximail.space.`                 | 300  |
| TXT   | `@`                | `v=spf1 a:mail.veximail.space ~all`       | 300  |
| TXT   | `_dmarc`           | `v=DMARC1; p=none; rua=mailto:postmaster@veximail.space` | 300  |

Опционально (если на этот IP не висит ничего стороннего):

| Тип   | Имя                | Значение                                  | TTL  |
|-------|--------------------|-------------------------------------------|------|
| A     | `@`                | `178.16.55.219`                          | 300  |

На старте держи TTL = 300. После того как всё проверишь — подними до 3600.

## PTR (reverse DNS)

Настраивается **в панели хостера**, не в зоне домена. Найди раздел вида
«Reverse DNS», «rDNS», «PTR» для IP сервера и задай:

```
178.16.55.219  →  mail.veximail.space
```

Проверка с любой машины:

```
dig -x 178.16.55.219 +short
```

Должно вернуть `mail.veximail.space.`. Согласованность обязательна:

```
PTR (rDNS)              = mail.veximail.space
myhostname (postfix)    = mail.veximail.space
SMTP banner             = mail.veximail.space ESMTP
A mail.veximail.space   = 178.16.55.219
```

## Проверка снаружи

```
dig MX veximail.space +short            # → 10 mail.veximail.space.
dig A mail.veximail.space +short        # → 178.16.55.219
dig TXT veximail.space +short           # → "v=spf1 a:mail.veximail.space ~all"
dig -x 178.16.55.219 +short            # → mail.veximail.space.
```
