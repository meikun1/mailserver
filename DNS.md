# DNS для veximail.xyz

Сервер: `178.236.248.118`. Все записи в зоне `veximail.xyz`.

| Тип   | Имя                | Значение                                  | TTL  |
|-------|--------------------|-------------------------------------------|------|
| A     | `mail`             | `178.236.248.118`                         | 300  |
| MX    | `@`                | `10 mail.veximail.xyz.`                    | 300  |
| TXT   | `@`                | `v=spf1 a:mail.veximail.xyz ~all`         | 300  |
| TXT   | `_dmarc`           | `v=DMARC1; p=none; rua=mailto:postmaster@veximail.xyz` | 300  |

Опционально (если на этот IP не висит ничего стороннего):

| Тип   | Имя                | Значение                                  | TTL  |
|-------|--------------------|-------------------------------------------|------|
| A     | `@`                | `178.236.248.118`                         | 300  |

Критичны только A `mail` + MX — для приёма кодов их достаточно. На старте держи
TTL = 300. После проверки — подними до 3600.

> В веб-панели регистратора имя MX — пусто/`@` (корень), значение —
> `mail.veximail.xyz` БЕЗ точки, priority `10`. Точка в конце нужна только в
> сыром зонном файле BIND.

## PTR (reverse DNS)

Настраивается **в панели хостера**, не в зоне домена. Раздел вида
«Reverse DNS», «rDNS», «PTR» для IP сервера:

```
178.236.248.118  →  mail.veximail.xyz
```

Проверка:

```
dig -x 178.236.248.118 +short
```

Должно вернуть `mail.veximail.xyz.`. Согласованность обязательна:

```
PTR (rDNS)              = mail.veximail.xyz
myhostname (postfix)    = mail.veximail.xyz
SMTP banner             = mail.veximail.xyz ESMTP
A mail.veximail.xyz     = 178.236.248.118
```

## Проверка снаружи

```
dig MX veximail.xyz +short              # → 10 mail.veximail.xyz.
dig A mail.veximail.xyz +short          # → 178.236.248.118
dig TXT veximail.xyz +short             # → "v=spf1 a:mail.veximail.xyz ~all"
dig -x 178.236.248.118 +short           # → mail.veximail.xyz.
```
