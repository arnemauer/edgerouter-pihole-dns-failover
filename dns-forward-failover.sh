#!/bin/bash
#
# dns-forward-failover.sh - DNS forwarding failover for a Pi-hole on a Ubiquiti EdgeRouter (EdgeOS)
#
# Setup: DHCP hands out the router as DNS server and the router (dnsmasq,
# 'service dns forwarding') forwards all queries to the Pi-hole.
#
# The script checks whether the Pi-hole answers DNS queries. After a number of
# consecutive failures the router forwards to the fallback servers instead. Once
# the Pi-hole has been healthy for a number of consecutive checks, the router
# forwards to the Pi-hole again. Clients notice this immediately; there is no
# need to wait for DHCP leases to expire.
#
# Installation (see README.md):
#   /config/scripts/dns-forward-failover.sh     (this script, chmod 755)
#   /config/scripts/dns-forward-failover.conf   (optional, overrides the defaults below)
#   set system task-scheduler task dns-failover executable path /config/scripts/dns-forward-failover.sh
#   set system task-scheduler task dns-failover interval 1m
#
# Manual usage:
#   dns-forward-failover.sh           normal run (used by the task scheduler)
#   dns-forward-failover.sh status    show health and current upstream, changes nothing
#

# ---------------------------------------------------------------------------
# Configuration (defaults; override them in /config/scripts/dns-forward-failover.conf)
# ---------------------------------------------------------------------------

# IP address of the Pi-hole to check.
PIHOLE_IP="192.168.1.2"

# Domains to query. The Pi-hole is healthy if at least one of them resolves.
# Use external domains, so the Pi-hole's own upstream is tested as well.
TEST_DOMAINS="cloudflare.com google.com"

# Timeout per query in seconds.
QUERY_TIMEOUT=2

# Router upstream server(s) while the Pi-hole is healthy (space separated).
PRIMARY_DNS="192.168.1.2"

# Router upstream server(s) while the Pi-hole is down (space separated).
FALLBACK_DNS="1.1.1.1 9.9.9.9"

# Number of consecutive failed checks before switching to the fallback.
FAIL_THRESHOLD=2

# Number of consecutive successful checks before switching back to the Pi-hole.
RECOVER_THRESHOLD=3

# Only switch to the fallback if the fallback itself works. Avoids pointless
# config changes when the whole internet connection is down.
REQUIRE_WORKING_FALLBACK=1

# 1 = also 'save' after a change (survives a reboot). 0 = commit only; after a
# reboot the saved config (Pi-hole) is active again and the script corrects
# itself within a few minutes. 0 avoids unnecessary flash writes.
SAVE_CONFIG=0

STATE_FILE="/var/run/dns-forward-failover.state"
LOCK_DIR="/var/run/dns-forward-failover.lock"
CLI_API="/bin/cli-shell-api"
CFG_WRAPPER="/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper"
CONF_FILE="${DNS_FAILOVER_CONF:-/config/scripts/dns-forward-failover.conf}"

# shellcheck source=/dev/null
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

# ---------------------------------------------------------------------------

MODE="${1:-run}"

# Config changes must be made with group vyattacfg; otherwise files in the
# config tree get the wrong permissions and later commits from the GUI/CLI fail.
if [ "$MODE" = "run" ] && getent group vyattacfg >/dev/null 2>&1 \
   && [ "$(id -g -n)" != "vyattacfg" ]; then
    exec sg vyattacfg -c "/bin/bash $(readlink -f "$0") $*"
fi

log() {
    logger -t dns-failover -- "$*"
    [ -t 1 ] && echo "$*"
}

# dns_query SERVER DOMAIN -> exit 0 if SERVER returns an A record for DOMAIN
dns_query() {
    local server=$1 domain=$2 out
    if command -v dig >/dev/null 2>&1; then
        out=$(dig +time="$QUERY_TIMEOUT" +tries=1 +short @"$server" "$domain" A 2>/dev/null) || return 1
        echo "$out" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    elif command -v host >/dev/null 2>&1; then
        out=$(host -W "$QUERY_TIMEOUT" -t A "$domain" "$server" 2>/dev/null) || return 1
        echo "$out" | grep -Eq 'has (IPv4 )?address'
    elif command -v nslookup >/dev/null 2>&1; then
        out=$(nslookup -timeout="$QUERY_TIMEOUT" -retry=0 "$domain" "$server" 2>/dev/null) || return 1
        echo "$out" | sed -n '/^Name:/,$p' | grep -q '^Address'
    else
        log "ERROR: no dig, host or nslookup found"
        return 2
    fi
}

# server_ok SERVER -> exit 0 if at least one test domain resolves
server_ok() {
    local d rc=1
    for d in $TEST_DOMAINS; do
        dns_query "$1" "$d"
        rc=$?
        [ $rc -eq 0 ] || [ $rc -eq 2 ] && return $rc
    done
    return 1
}

# any_ok "IP IP ..." -> exit 0 if at least one of the servers works
any_ok() {
    local s
    for s in $1; do
        server_ok "$s" && return 0
    done
    return 1
}

# get_dns -> current (active) upstream servers of dns forwarding
get_dns() {
    local vals
    vals=$("$CLI_API" returnActiveValues service dns forwarding name-server 2>/dev/null)
    eval "set -- $vals"
    echo "$*"
}

# norm "a b c" -> normalised list for comparison
norm() {
    echo $1
}

# upstream_is "IP IP ..." -> exit 0 if the router forwards to exactly these servers
upstream_is() {
    [ "$(norm "$(get_dns)")" = "$(norm "$1")" ]
}

# apply_dns "IP IP ..." -> set the upstream servers of dns forwarding
apply_dns() {
    local list=$1 ip rc=0
    "$CFG_WRAPPER" begin || return 1
    "$CFG_WRAPPER" delete service dns forwarding name-server >/dev/null 2>&1
    for ip in $list; do
        "$CFG_WRAPPER" set service dns forwarding name-server "$ip" || rc=1
    done
    if [ $rc -eq 0 ] && "$CFG_WRAPPER" commit; then
        if [ "$SAVE_CONFIG" = "1" ]; then
            "$CFG_WRAPPER" save >/dev/null || log "WARNING: save failed"
        fi
        "$CFG_WRAPPER" end
        return 0
    fi
    "$CFG_WRAPPER" discard >/dev/null 2>&1
    "$CFG_WRAPPER" end
    return 1
}

show_status() {
    if server_ok "$PIHOLE_IP"; then
        echo "Pi-hole $PIHOLE_IP: OK"
    else
        echo "Pi-hole $PIHOLE_IP: NO ANSWER"
    fi
    echo "dns forwarding name-server: $(get_dns)"
    [ -f "$STATE_FILE" ] && echo "State: $(tr '\n' ' ' < "$STATE_FILE")"
}

if [ "$MODE" = "status" ]; then
    show_status
    exit 0
fi

# Prevent two runs at the same time (e.g. when a commit takes long).
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Remove a stale lock (older than 10 minutes), otherwise stop.
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

FAILS=0
OKS=0
# shellcheck source=/dev/null
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

server_ok "$PIHOLE_IP"
case $? in
    0) OKS=$((OKS + 1)); FAILS=0 ;;
    2) exit 1 ;;
    *) FAILS=$((FAILS + 1)); OKS=0 ;;
esac
# Cap the counters
[ "$FAILS" -gt "$FAIL_THRESHOLD" ] && FAILS=$FAIL_THRESHOLD
[ "$OKS" -gt "$RECOVER_THRESHOLD" ] && OKS=$RECOVER_THRESHOLD

printf 'FAILS=%d\nOKS=%d\n' "$FAILS" "$OKS" > "$STATE_FILE"

if [ "$FAILS" -ge "$FAIL_THRESHOLD" ]; then
    if ! upstream_is "$FALLBACK_DNS"; then
        if [ "$REQUIRE_WORKING_FALLBACK" = "1" ] && ! any_ok "$FALLBACK_DNS"; then
            log "Pi-hole $PIHOLE_IP is not answering, but neither is the fallback ($FALLBACK_DNS); probably an internet outage, nothing changed"
            exit 0
        fi
        log "Pi-hole $PIHOLE_IP is not answering ($FAILS checks), dns forwarding -> $FALLBACK_DNS"
        apply_dns "$FALLBACK_DNS" || log "ERROR: switching dns forwarding to fallback failed"
    fi
elif [ "$OKS" -ge "$RECOVER_THRESHOLD" ]; then
    if ! upstream_is "$PRIMARY_DNS"; then
        log "Pi-hole $PIHOLE_IP is answering again ($OKS checks), dns forwarding -> $PRIMARY_DNS"
        apply_dns "$PRIMARY_DNS" || log "ERROR: switching dns forwarding back to Pi-hole failed"
    fi
fi

exit 0
