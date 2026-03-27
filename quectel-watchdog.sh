#!/bin/bash
# Quectel RM520N-GL watchdog
# Monitors wwan0 connectivity and reconnects if needed

[ -f /etc/quectel.conf ] && source /etc/quectel.conf

CHECK_INTERVAL=30
FAIL_THRESHOLD=3
PING_TARGET="${PING_TARGET:-8.8.8.8}"

fail_count=0

log() {
    echo "[watchdog] $1"
}

reconnect() {
    log "Reconnecting..."
    ip link set wwan0 down 2>/dev/null || true
    systemctl restart quectel-connect.service
    log "quectel-connect.service restarted, waiting 90s for it to complete..."
    sleep 90
    fail_count=0
    log "Resuming health checks"
}

log "Started. Checking every ${CHECK_INTERVAL}s, threshold ${FAIL_THRESHOLD} failures."

while true; do
    sleep "$CHECK_INTERVAL"

    # Check ModemManager is running
    if ! systemctl is-active ModemManager > /dev/null 2>&1; then
        fail_count=$((fail_count + 1))
        log "WARNING: ModemManager is not running (fail ${fail_count}/${FAIL_THRESHOLD})"
        if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
            log "Restarting ModemManager..."
            systemctl restart ModemManager
            sleep 30
            fail_count=0
        fi
        continue
    fi

    # Check bearer state via ModemManager
    MODEM_INDEX=$(mmcli -L 2>/dev/null | grep -oP '/org/freedesktop/ModemManager1/Modem/\K[0-9]+' | head -1)
    if [ -z "$MODEM_INDEX" ]; then
        fail_count=$((fail_count + 1))
        log "WARNING: modem not found (fail ${fail_count}/${FAIL_THRESHOLD})"
        [ "$fail_count" -ge "$FAIL_THRESHOLD" ] && reconnect
        continue
    fi

    BEARER_STATE=$(mmcli -m "$MODEM_INDEX" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -v 'power state\|packet service' | grep -oP '(?<=state: )[\w]+')
    if [ "$BEARER_STATE" != "connected" ]; then
        fail_count=$((fail_count + 1))
        log "WARNING: modem state is '${BEARER_STATE}' (fail ${fail_count}/${FAIL_THRESHOLD})"
        [ "$fail_count" -ge "$FAIL_THRESHOLD" ] && reconnect
        continue
    fi

    # Check actual traffic path via ping
    IP_ADDR=$(ip addr show wwan0 2>/dev/null | grep -oP '(?<=inet )[\d.]+' | head -1)
    if [ -z "$IP_ADDR" ]; then
        fail_count=$((fail_count + 1))
        log "WARNING: wwan0 has no IP address (fail ${fail_count}/${FAIL_THRESHOLD})"
        [ "$fail_count" -ge "$FAIL_THRESHOLD" ] && reconnect
        continue
    fi

    if ! ping -I wwan0 -c 2 -W 5 "$PING_TARGET" > /dev/null 2>&1; then
        fail_count=$((fail_count + 1))
        log "WARNING: ping to ${PING_TARGET} via wwan0 failed (fail ${fail_count}/${FAIL_THRESHOLD})"
        [ "$fail_count" -ge "$FAIL_THRESHOLD" ] && reconnect
        continue
    fi

    # All checks passed
    if [ "$fail_count" -gt 0 ]; then
        log "OK: connectivity restored (resetting fail counter)"
    fi
    fail_count=0
done
