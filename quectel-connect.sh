#!/bin/bash
# Quectel RM520N-GL connection script
# Connects via ModemManager QMI and configures wwan0

[ -f /etc/quectel.conf ] && source /etc/quectel.conf
APN="${APN:-internet}"

MODEM_INDEX=""
MAX_WAIT=60
WAITED=0

echo "[quectel] Waiting for modem..."
while [ -z "$MODEM_INDEX" ]; do
    MODEM_PATH=$(mmcli -L 2>/dev/null | grep -oP '/org/freedesktop/ModemManager1/Modem/\K[0-9]+' | head -1)
    if [ -n "$MODEM_PATH" ]; then
        MODEM_INDEX="$MODEM_PATH"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "[quectel] ERROR: modem not found after ${MAX_WAIT}s"
        exit 1
    fi
done

echo "[quectel] Found modem index: $MODEM_INDEX"

# Wait for registered state
echo "[quectel] Waiting for registration..."
WAITED=0
while true; do
    STATE=$(mmcli -m "$MODEM_INDEX" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -v 'power state\|packet service' | grep -oP '(?<=state: )[\w]+')
    if [ "$STATE" = "registered" ] || [ "$STATE" = "connected" ]; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "[quectel] ERROR: modem not registered after ${MAX_WAIT}s (state: $STATE)"
        exit 1
    fi
done

if [ "$STATE" = "connected" ]; then
    echo "[quectel] Already connected, reconfiguring interface..."
else
    echo "[quectel] Connecting with APN=${APN}..."
    mmcli -m "$MODEM_INDEX" --simple-connect="apn=${APN},ip-type=ipv4"
fi

# Find the data bearer (type=default, not default-attach)
BEARER_INDEX=$(mmcli -m "$MODEM_INDEX" 2>/dev/null | grep -oP '(?<=bearer paths: ).*' | grep -oP '[0-9]+' | head -1)
if [ -z "$BEARER_INDEX" ]; then
    # Try listing all bearers
    BEARER_INDEX=$(mmcli -m "$MODEM_INDEX" 2>/dev/null | grep -oP '/org/freedesktop/ModemManager1/Bearer/\K[0-9]+' | tail -1)
fi

if [ -z "$BEARER_INDEX" ]; then
    echo "[quectel] ERROR: no bearer found after connect"
    exit 1
fi
echo "[quectel] Using bearer: $BEARER_INDEX"

# Get IP settings from bearer
IP_ADDR=$(mmcli -b "$BEARER_INDEX" 2>/dev/null | grep -oP '(?<=address: )[\d.]+')
IP_PREFIX=$(mmcli -b "$BEARER_INDEX" 2>/dev/null | grep -oP '(?<=prefix: )[\d]+')
GW=$(mmcli -b "$BEARER_INDEX" 2>/dev/null | grep -oP '(?<=gateway: )[\d.]+')
DNS1=$(mmcli -b "$BEARER_INDEX" 2>/dev/null | grep -oP '(?<=dns: )[\d.]+' | head -1)
DNS2=$(mmcli -b "$BEARER_INDEX" 2>/dev/null | grep -oP '(?<=dns: )[\d.]+' | tail -1)

if [ -z "$IP_ADDR" ] || [ -z "$IP_PREFIX" ] || [ -z "$GW" ]; then
    echo "[quectel] ERROR: incomplete bearer data (IP=${IP_ADDR}, PREFIX=${IP_PREFIX}, GW=${GW})"
    exit 1
fi

echo "[quectel] IP: ${IP_ADDR}/${IP_PREFIX}, GW: ${GW}, DNS: ${DNS1} ${DNS2}"

# Configure wwan0
ip link set wwan0 up || { echo "[quectel] ERROR: failed to bring up wwan0"; exit 1; }
ip addr flush dev wwan0
ip addr add "${IP_ADDR}/${IP_PREFIX}" dev wwan0 || { echo "[quectel] ERROR: failed to assign IP ${IP_ADDR}/${IP_PREFIX}"; exit 1; }
ip route add default via "$GW" dev wwan0 metric 700 2>/dev/null || true

# Policy routing: traffic from wwan0 IP always exits via wwan0.
# REQUIRED when other default routes exist (WiFi/Ethernet).
# Without this, sockets bound to wwan0 IP send data out via WiFi,
# causing the carrier to receive packets with a private source IP it
# can't reverse-NAT back — ACKs never return and TCP upload stalls within 1s.
ip rule del from "${IP_ADDR}" table 100 2>/dev/null || true
ip rule add from "${IP_ADDR}" table 100 || { echo "[quectel] ERROR: failed to add policy rule for ${IP_ADDR}"; exit 1; }
ip route flush table 100 2>/dev/null || true
ip route add default via "$GW" dev wwan0 table 100 || { echo "[quectel] ERROR: failed to add route in table 100"; exit 1; }

# Set DNS (only for wwan0 usage - doesn't override system DNS)
echo "nameserver $DNS1" > /etc/resolv.conf.wwan0
[ -n "$DNS2" ] && echo "nameserver $DNS2" >> /etc/resolv.conf.wwan0

echo "[quectel] wwan0 up: ${IP_ADDR}/${IP_PREFIX} via ${GW}"
echo "[quectel] Policy routing: traffic from ${IP_ADDR} → table 100 → wwan0"

# Verify connectivity
echo "[quectel] Verifying connectivity..."
if ping -I wwan0 -c 2 -W 5 "$GW" > /dev/null 2>&1; then
    echo "[quectel] OK: gateway ${GW} reachable"
else
    echo "[quectel] WARNING: gateway ${GW} not responding to ping (interface may still work)"
fi
