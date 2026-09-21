#!/usr/bin/env python3
"""Bounded, privacy-safe staging OTP and transactional-mail acceptance check."""

from __future__ import annotations

import email
import imaplib
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from email.header import decode_header
from html import unescape


def required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required staging acceptance variable: {name}")
    return value


APP_URL = required("APP_URL").rstrip("/")
SUPABASE_URL = required("NEXT_PUBLIC_SUPABASE_URL").rstrip("/")
ANON_KEY = required("NEXT_PUBLIC_SUPABASE_ANON_KEY")
TEST_EMAIL = required("TEST_EMAIL_1").lower()
IMAP_HOST = required("IMAP_HOST")
IMAP_PORT = int(required("IMAP_PORT"))
IMAP_USER = required("IMAP_USER_1")
IMAP_PASSWORD = required("IMAP_PASSWORD_1")
RUN_ID = f"DPH-{uuid.uuid4().hex[:12]}"


def http_json(url: str, body: dict, headers: dict[str, str]) -> tuple[int, dict]:
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        method="POST",
        headers={"Content-Type": "application/json", **headers},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = response.read()
            return response.status, json.loads(payload) if payload else {}
    except urllib.error.HTTPError as error:
        error.read()
        raise RuntimeError(f"Staging request failed at {urllib.parse.urlparse(url).path} with HTTP {error.code}.") from error


def connect() -> imaplib.IMAP4:
    secure = required("IMAP_SECURE").lower() in {"1", "true", "yes", "ssl"}
    if secure:
        client: imaplib.IMAP4 = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT, ssl_context=ssl.create_default_context())
    else:
        client = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
        client.starttls(ssl_context=ssl.create_default_context())
    client.login(IMAP_USER, IMAP_PASSWORD)
    client.select("INBOX")
    return client


def max_uid(client: imaplib.IMAP4) -> int:
    status, data = client.uid("search", None, "ALL")
    if status != "OK" or not data or not data[0]:
        return 0
    return max(int(value) for value in data[0].split())


def decoded_header(value: str | None) -> str:
    result = []
    for part, charset in decode_header(value or ""):
        result.append(part.decode(charset or "utf-8", errors="replace") if isinstance(part, bytes) else part)
    return "".join(result)


def message_text(message: email.message.Message) -> str:
    parts = []
    for part in message.walk() if message.is_multipart() else [message]:
        if part.get_content_maintype() == "text" and part.get_content_disposition() != "attachment":
            payload = part.get_payload(decode=True) or b""
            parts.append(payload.decode(part.get_content_charset() or "utf-8", errors="replace"))
    return unescape(re.sub(r"<[^>]+>", " ", "\n".join(parts)))


def wait_for(client: imaplib.IMAP4, after_uid: int, subject: str, contains: str | None = None) -> tuple[int, email.message.Message, str]:
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        client.noop()
        status, data = client.uid("search", None, f"UID {after_uid + 1}:*")
        if status == "OK" and data and data[0]:
            for raw_uid in reversed(data[0].split()):
                uid = int(raw_uid)
                status, fetched = client.uid("fetch", raw_uid, "(RFC822)")
                if status != "OK" or not fetched or not isinstance(fetched[0], tuple):
                    continue
                message = email.message_from_bytes(fetched[0][1])
                text = message_text(message)
                if decoded_header(message.get("Subject")) == subject and TEST_EMAIL in decoded_header(message.get("To")).lower() and (contains is None or contains in text):
                    return uid, message, text
        time.sleep(5)
    raise RuntimeError(f"No matching staging message arrived for acceptance run {RUN_ID}.")


imap = connect()
try:
    before_otp = max_uid(imap)
    http_json(
        f"{SUPABASE_URL}/auth/v1/otp",
        {"email": TEST_EMAIL, "create_user": True},
        {"apikey": ANON_KEY, "Authorization": f"Bearer {ANON_KEY}"},
    )
    otp_uid, otp_message, otp_text = wait_for(imap, before_otp, "Je zescijferige inlogcode")
    otp_match = re.search(r"(?<!\d)(\d{6})(?!\d)", otp_text)
    if not otp_match:
        raise RuntimeError("The received staging OTP message did not contain a six-digit code.")
    if "halloween@duindorpdoet.nl" not in decoded_header(otp_message.get("From")).lower():
        raise RuntimeError("The staging OTP sender does not match the configured event mailbox.")

    status, verification = http_json(
        f"{SUPABASE_URL}/auth/v1/verify",
        {"email": TEST_EMAIL, "token": otp_match.group(1), "type": "email"},
        {"apikey": ANON_KEY, "Authorization": f"Bearer {ANON_KEY}"},
    )
    if status != 200 or not verification.get("access_token"):
        raise RuntimeError("The received OTP could not be verified against staging Supabase Auth.")

    before_contact = max(before_otp, otp_uid, max_uid(imap))
    http_json(
        f"{APP_URL}/api/public/contact",
        {
            "name": "Geautomatiseerde stagingacceptatie",
            "email": TEST_EMAIL,
            "subject": RUN_ID,
            "body": f"Transactionele mailacceptatie {RUN_ID}",
            "website": "",
            "startedAt": int(time.time() * 1000) - 5000,
        },
        {"Origin": APP_URL, "X-Request-ID": RUN_ID},
    )
    _, contact_message, contact_text = wait_for(imap, before_contact, "Je bericht is ontvangen", RUN_ID)
    if "halloween@duindorpdoet.nl" not in decoded_header(contact_message.get("From")).lower() or APP_URL not in contact_text:
        raise RuntimeError("The staging transactional message has an unexpected sender or environment URL.")

    imap.uid("store", str(otp_uid), "+FLAGS.SILENT", "(\\Seen)")
    print(f"Staging OTP and transactional mail acceptance passed ({RUN_ID}).")
finally:
    try:
        imap.logout()
    except Exception:
        pass
