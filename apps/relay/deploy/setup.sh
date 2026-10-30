#!/usr/bin/env bash
# One-time setup of the relay on the valdoh.com server. Run as valdo:
#   curl -fsSL https://raw.githubusercontent.com/iam-oov/proyector-13/main/apps/relay/deploy/setup.sh | sudo bash
# Safe to run again: every step checks before it changes anything.
set -euo pipefail

REPO=https://github.com/iam-oov/proyector-13.git
DIR=/home/memodi/proyector-13
UV=/home/memodi/.local/bin/uv
UNIT=/etc/systemd/system/proyector-relay.service
SUDOERS=/etc/sudoers.d/proyector-relay

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -x "$UV" ] || { echo "missing $UV (uv for the memodi user)"; exit 1; }

# 1. Checkout owned by memodi. `sudo git clone` would leave it owned by root
#    and break the CI deploy's `git reset --hard` (same trap as valdoh.com).
if [ ! -d "$DIR/.git" ]; then
  sudo -u memodi git clone "$REPO" "$DIR"
fi
chown -R memodi:memodi "$DIR"

# 2. Python 3.15 and dependencies, only for the relay (system python3 stays as is).
sudo -u memodi -H bash -c "cd $DIR/apps/relay && $UV python install 3.15 && $UV sync --frozen --no-dev"

# 3. Service.
install -m 644 "$DIR/apps/relay/deploy/proyector-relay.service" "$UNIT"
systemctl daemon-reload
systemctl enable --now proyector-relay

# 4. Let the CI deploy (as memodi) restart this one service and nothing else.
echo 'memodi ALL=(root) NOPASSWD: /usr/bin/systemctl restart proyector-relay' > "$SUDOERS.tmp"
chmod 440 "$SUDOERS.tmp"
visudo -cf "$SUDOERS.tmp" >/dev/null
mv "$SUDOERS.tmp" "$SUDOERS"

# 5. Check.
for _ in $(seq 1 10); do
  if curl -fsS http://127.0.0.1:8090/proyector/version.json; then
    echo
    echo "OK: relay running on 127.0.0.1:8090"
    exit 0
  fi
  sleep 1
done
echo "relay did not answer; see: journalctl -u proyector-relay -n 50"
exit 1
