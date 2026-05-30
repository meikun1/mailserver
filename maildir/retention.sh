#!/bin/sh
set -e

CATCHALL_ADDR=__CATCHALL_ADDR__
RETENTION_DAYS=7

if ! systemctl is-active --quiet dovecot; then
  exit 0
fi

doveadm expunge -u "$CATCHALL_ADDR" mailbox INBOX SAVEDBEFORE "${RETENTION_DAYS}d" >/dev/null 2>&1 || true
