#!/usr/bin/env python3
import email
import email.policy
import imaplib
import json
import os
import re
import sys
import time
from email.utils import parseaddr
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

IMAP_HOST     = os.environ["IMAP_HOST"]
IMAP_USER     = os.environ["IMAP_USER"]
IMAP_PASS     = os.environ["IMAP_PASS"]
TG_BOT_TOKEN  = os.environ["TG_BOT_TOKEN"]
TG_CHAT_ID    = os.environ["TG_CHAT_ID"]
STATE_DIR     = Path(os.environ.get("STATE_DIR", "/var/lib/tgbot"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "15"))
SEND_NO_CODE  = os.environ.get("SEND_NO_CODE", "0") == "1"

LAST_UID_FILE = STATE_DIR / "last_uid"

_KEYWORDS = (
    r"code|код|пароль|password|verify|verification|подтвержд|подтверди|"
    r"пин|pin|otp|otc|одноразов"
)
CODE_KEYWORD_RE = re.compile(
    rf"(?:{_KEYWORDS})[^\d\n]{{0,40}}?(\d{{4,10}})",
    re.IGNORECASE,
)
CODE_GENERIC_RE = re.compile(r"\b(\d{4,8})\b")


def log(msg):
    print(msg, flush=True)


def get_last_uid():
    try:
        return int(LAST_UID_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return 0


def set_last_uid(uid):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = LAST_UID_FILE.with_suffix(".tmp")
    tmp.write_text(str(uid))
    tmp.replace(LAST_UID_FILE)


def message_text(msg):
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                try:
                    return part.get_content()
                except Exception:
                    pass
        for part in msg.walk():
            if part.get_content_type() == "text/html":
                try:
                    return re.sub(r"<[^>]+>", " ", part.get_content())
                except Exception:
                    pass
        return ""
    try:
        return msg.get_content()
    except Exception:
        return ""


def extract_code(text):
    if not text:
        return None
    m = CODE_KEYWORD_RE.search(text)
    if m:
        return m.group(1)
    m = CODE_GENERIC_RE.search(text)
    if m:
        return m.group(1)
    return None


def get_recipient(msg):
    for h in ("X-Original-To", "Delivered-To", "To"):
        val = msg.get(h)
        if not val:
            continue
        addr = parseaddr(str(val))[1]
        if addr:
            return addr
        return str(val).strip()
    return ""


def get_sender(msg):
    val = msg.get("From", "")
    addr = parseaddr(str(val))[1]
    return addr or str(val).strip()


def html_escape(s):
    s = "" if s is None else str(s)
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def send_telegram(text):
    data = json.dumps({
        "chat_id": TG_CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }).encode("utf-8")
    req = Request(
        f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(req, timeout=15) as resp:
        return resp.read()


def format_with_code(msg, code, recipient):
    sender  = get_sender(msg)
    subject = str(msg.get("Subject", "") or "(no subject)")
    return (
        f"<b>To:</b>   <code>{html_escape(recipient)}</code>\n"
        f"<b>Code:</b> <code>{html_escape(code)}</code>\n"
        f"<b>From:</b> {html_escape(sender)}\n"
        f"<b>Subject:</b> {html_escape(subject)}"
    )


def format_without_code(msg, recipient):
    sender  = get_sender(msg)
    subject = str(msg.get("Subject", "") or "(no subject)")
    return (
        f"<b>To:</b>   <code>{html_escape(recipient)}</code>\n"
        f"<b>From:</b> {html_escape(sender)}\n"
        f"<b>Subject:</b> {html_escape(subject)}\n"
        f"<i>(no code detected)</i>"
    )


def process_one(raw_bytes):
    try:
        msg = email.message_from_bytes(raw_bytes, policy=email.policy.default)
    except Exception as e:
        log(f"parse error: {e}")
        return
    recipient = get_recipient(msg)
    text = message_text(msg)
    code = extract_code(text)
    if code:
        body = format_with_code(msg, code, recipient)
    elif SEND_NO_CODE:
        body = format_without_code(msg, recipient)
    else:
        log(f"skip (no code): to={recipient!r} subject={msg.get('Subject')!r}")
        return
    try:
        send_telegram(body)
        log(f"sent code={code!r} to chat for recipient={recipient!r}")
    except (HTTPError, URLError) as e:
        log(f"telegram send error: {e}")
        raise


def initialize_baseline(imap):
    typ, data = imap.uid("search", None, "ALL")
    if typ != "OK" or not data or not data[0]:
        return 0
    return max(int(x) for x in data[0].split())


def loop_imap():
    last = get_last_uid()
    log(f"connecting to {IMAP_HOST}:993 as {IMAP_USER} (last_uid={last})")
    with imaplib.IMAP4_SSL(IMAP_HOST) as imap:
        imap.login(IMAP_USER, IMAP_PASS)
        imap.select("INBOX")
        if last == 0:
            last = initialize_baseline(imap)
            set_last_uid(last)
            log(f"baseline set to {last}; will only process strictly newer mail")
        while True:
            typ, data = imap.uid("search", None, f"UID {last + 1}:*")
            if typ == "OK" and data and data[0]:
                uids = sorted({int(x) for x in data[0].split() if int(x) > last})
                for uid in uids:
                    typ, raw = imap.uid("fetch", str(uid), "(RFC822)")
                    if typ != "OK" or not raw or not raw[0]:
                        continue
                    process_one(raw[0][1])
                    last = uid
                    set_last_uid(last)
            try:
                imap.noop()
            except Exception:
                raise
            time.sleep(POLL_INTERVAL)


def main():
    backoff = 5
    while True:
        try:
            loop_imap()
            backoff = 5
        except KeyboardInterrupt:
            sys.exit(0)
        except Exception as e:
            log(f"loop error: {e!r}; reconnecting in {backoff}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    main()
