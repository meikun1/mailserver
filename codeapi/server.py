#!/usr/bin/env python3
import email
import email.policy
import os
import re
from datetime import datetime, timezone
from email.utils import parseaddr, parsedate_to_datetime
from pathlib import Path

from flask import Flask, abort, jsonify, request

MAILDIR = Path(os.environ.get(
    "CODEAPI_MAILDIR",
    "/var/mail/vhosts/veximail.space/catchall/Maildir",
))
API_TOKEN = os.environ.get("CODEAPI_TOKEN", "")

if not API_TOKEN:
    raise SystemExit("CODEAPI_TOKEN env var required")

_KEYWORDS = (
    r"code|код|пароль|password|verify|verification|подтвержд|подтверди|"
    r"пин|pin|otp|otc|одноразов"
)
CODE_KEYWORD_RE = re.compile(
    rf"(?:{_KEYWORDS})[^\d\n]{{0,40}}?(\d{{4,10}})",
    re.IGNORECASE,
)
CODE_GENERIC_RE = re.compile(r"\b(\d{4,8})\b")

SERVICE_RULES = [
    ("telegram", re.compile(r"\btelegram\b", re.IGNORECASE)),
    ("github",   re.compile(r"\bgithub\b",   re.IGNORECASE)),
    ("google",   re.compile(r"\bgoogle\b|accounts\.google",     re.IGNORECASE)),
    ("apple",    re.compile(r"\bapple\.com\b|\bapple\s*id\b",   re.IGNORECASE)),
    ("discord",  re.compile(r"\bdiscord\b",  re.IGNORECASE)),
    ("microsoft",re.compile(r"\bmicrosoft\b|outlook\.com",      re.IGNORECASE)),
    ("steam",    re.compile(r"steampowered|steam\s*guard",      re.IGNORECASE)),
    ("vk",       re.compile(r"@vk\.com|vkontakte",              re.IGNORECASE)),
]

app = Flask(__name__)


def require_auth():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        abort(401)
    if auth[7:].strip() != API_TOKEN:
        abort(401)


def iter_maildir():
    for sub in ("new", "cur"):
        d = MAILDIR / sub
        if not d.is_dir():
            continue
        for f in d.iterdir():
            if f.is_file():
                yield f


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


def detect_service(*chunks):
    blob = " ".join(c or "" for c in chunks)
    for name, rx in SERVICE_RULES:
        if rx.search(blob):
            return name
    return None


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


def parse_one(path):
    try:
        with path.open("rb") as fh:
            msg = email.message_from_binary_file(fh, policy=email.policy.default)
    except Exception:
        return None
    text = message_text(msg)
    code = extract_code(text)
    if not code:
        return None
    sender    = get_sender(msg)
    recipient = get_recipient(msg)
    subject   = str(msg.get("Subject", ""))
    service   = detect_service(text, sender, subject)
    raw_date  = msg.get("Date")
    try:
        received = parsedate_to_datetime(raw_date) if raw_date else None
    except Exception:
        received = None
    if received is None:
        received = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    return {
        "code":        code,
        "service":     service,
        "to":          recipient,
        "from":        sender,
        "subject":     subject,
        "received_at": received.isoformat(),
        "file":        path.name,
    }


def collect(service=None, to=None, limit=50):
    items = []
    for f in iter_maildir():
        rec = parse_one(f)
        if rec is None:
            continue
        if service and rec["service"] != service:
            continue
        if to and rec["to"].lower() != to.lower():
            continue
        items.append(rec)
    items.sort(key=lambda r: r["received_at"], reverse=True)
    return items[:limit]


@app.get("/health")
def health():
    return jsonify({
        "ok": True,
        "maildir": str(MAILDIR),
        "exists": MAILDIR.exists(),
    })


@app.get("/codes")
def list_codes():
    require_auth()
    service = request.args.get("service")
    to      = request.args.get("to")
    try:
        limit = max(1, min(200, int(request.args.get("limit", "20"))))
    except ValueError:
        limit = 20
    return jsonify(collect(service=service, to=to, limit=limit))


@app.get("/codes/latest")
def latest_code():
    require_auth()
    service = request.args.get("service")
    to      = request.args.get("to")
    items = collect(service=service, to=to, limit=1)
    if not items:
        abort(404)
    return jsonify(items[0])


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)
