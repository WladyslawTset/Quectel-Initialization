#!/bin/bash
# Quectel RM520N-GL — installation script
# Installs packages, deploys connect script and systemd service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECT_SCRIPT_SRC="$SCRIPT_DIR/quectel-connect.sh"
CONNECT_SCRIPT_DST="/usr/local/bin/quectel-connect.sh"
WATCHDOG_SCRIPT_SRC="$SCRIPT_DIR/quectel-watchdog.sh"
WATCHDOG_SCRIPT_DST="/usr/local/bin/quectel-watchdog.sh"
SERVICE_FILE="/etc/systemd/system/quectel-connect.service"
WATCHDOG_SERVICE_FILE="/etc/systemd/system/quectel-watchdog.service"

if [ "$EUID" -ne 0 ]; then
    echo "[install] ERROR: run as root or with sudo"
    exit 1
fi

if [ ! -f "$CONNECT_SCRIPT_SRC" ]; then
    echo "[install] ERROR: quectel-connect.sh not found in $SCRIPT_DIR"
    exit 1
fi

if [ ! -f "$WATCHDOG_SCRIPT_SRC" ]; then
    echo "[install] ERROR: quectel-watchdog.sh not found in $SCRIPT_DIR"
    exit 1
fi

echo "[install] Installing packages..."
apt-get update -qq
apt-get install -y modemmanager libqmi-utils libmbim-utils minicom

echo "[install] Enabling ModemManager..."
systemctl enable ModemManager
systemctl start ModemManager

echo "[install] Deploying scripts..."
cp "$CONNECT_SCRIPT_SRC" "$CONNECT_SCRIPT_DST"
chmod +x "$CONNECT_SCRIPT_DST"
cp "$WATCHDOG_SCRIPT_SRC" "$WATCHDOG_SCRIPT_DST"
chmod +x "$WATCHDOG_SCRIPT_DST"

echo "[install] Creating systemd services..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Quectel RM520N-GL modem connect
After=ModemManager.service network.target
Wants=ModemManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$CONNECT_SCRIPT_DST
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > "$WATCHDOG_SERVICE_FILE" <<EOF
[Unit]
Description=Quectel RM520N-GL watchdog
After=quectel-connect.service
Requires=quectel-connect.service

[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT_DST
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable quectel-connect.service
systemctl start quectel-connect.service
systemctl enable quectel-watchdog.service
systemctl start quectel-watchdog.service

echo ""
echo "[install] Done. Check status with:"
echo "  sudo systemctl status quectel-connect.service"
echo "  sudo systemctl status quectel-watchdog.service"
echo "  sudo journalctl -u quectel-watchdog.service -f"
