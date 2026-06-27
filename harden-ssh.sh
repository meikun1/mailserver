#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must run as root" >&2
  exit 1
fi

if ! [[ -s /root/.ssh/authorized_keys ]]; then
  cat >&2 <<'EOF'
FATAL: /root/.ssh/authorized_keys is empty or missing.
Add your SSH key first FROM YOUR LOCAL MACHINE:
  ssh-copy-id root@<server-ip>
Then re-run this script ON THE SERVER.
EOF
  exit 1
fi

echo "Authorized keys currently installed:"
ssh-keygen -l -f /root/.ssh/authorized_keys

read -rp "Disable password login and enable key-only access? [y/N] " ans
case "$ans" in
  y|Y|yes|Yes) ;;
  *) echo "aborted"; exit 0 ;;
esac

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-harden.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
EOF
chmod 0644 /etc/ssh/sshd_config.d/99-harden.conf

sshd -t

systemctl reload ssh

cat <<'EOF'

SSH hardened. ROOT KEEPS access only via your installed SSH key.

CRITICAL: from a NEW terminal on your local machine, verify you can
still log in BEFORE closing the current session:

  ssh root@<server-ip>

If that fails, the current session is your only way back; revert with:

  rm /etc/ssh/sshd_config.d/99-harden.conf
  systemctl reload ssh
EOF
