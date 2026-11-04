#!/bin/bash
#
# bobs_basic_firestarter.sh - Slackware very basic firewall setup
# Copyright (c) 2026 Epoch
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# ----------------------------------------------------------------------
# Simple dual-stack nftables firewall installer for Slackware.
#
# Intended for a single-user workstation.
#
#   INPUT    default DROP
#   FORWARD  default DROP
#   OUTPUT   default ACCEPT
#
# Permits:
#   - loopback
#   - replies to connections initiated by this machine
#   - DHCPv4 client replies
#   - DHCPv6 client replies
#   - IPv6 Neighbor Discovery / Router Advertisements
#   - essential ICMPv6 error messages
#
# Blocks unsolicited inbound TCP/UDP connections.
#
# Installs:
#   /etc/nftables.conf
#   /etc/rc.d/rc.firewall
#
# Slackware enables rc scripts by making them executable.
#
# This is an optional helper. It does not replace or modify Slackware's
# existing networking configuration machinery other than installing the
# explicitly named files above.
# ----------------------------------------------------------------------

set -euo pipefail

PROGRAM='bobs_basic_firestarter.sh'
VERSION='1.0-bash'

NFT='/usr/sbin/nft'
NFTABLES_CONF='/etc/nftables.conf'
RC_FIREWALL='/etc/rc.d/rc.firewall'

SUCCESS=0

TMP_RULES=''
TMP_RC=''

# ----------------------------------------------------------------------
# Logging / errors
# ----------------------------------------------------------------------

log() {
    echo "$*"
}

die() {
    echo "" >&2
    echo "ERROR: $*" >&2
    echo "" >&2
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root."
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------

cleanup() {
    [[ -n "$TMP_RULES" && -e "$TMP_RULES" ]] && rm -f -- "$TMP_RULES"
    [[ -n "$TMP_RC" && -e "$TMP_RC" ]] && rm -f -- "$TMP_RC"
}

trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------
# Timestamp
# ----------------------------------------------------------------------

timestamp() {
    date '+%Y%m%d-%H%M%S'
}

# ----------------------------------------------------------------------
# Backup an existing file.
#
# Backups are deliberately timestamped rather than overwritten.
# ----------------------------------------------------------------------

backup_file() {
    local file="$1"

    [[ -e "$file" ]] || return 0

    local stamp
    stamp=$(timestamp)

    local backup="${file}.backup-${stamp}"

    # Avoid accidentally overwriting an existing backup if two invocations
    # happen within the same second.
    local n=1

    while [[ -e "$backup" ]]; do
        backup="${file}.backup-${stamp}-${n}"
        ((n++))
    done

    cp -a -- "$file" "$backup" ||
        die "Cannot back up $file to $backup."

    log "Backed up $file to $backup"
}

# ----------------------------------------------------------------------
# Create a temporary file in the same directory as its destination.
#
# Keeping the temporary file on the same filesystem makes the final mv
# atomic.
# ----------------------------------------------------------------------

make_temp_file() {
    local destination="$1"

    local directory
    directory=$(dirname -- "$destination")

    mkdir -p -- "$directory" ||
        die "Cannot access destination directory: $directory"

    local tmp
    tmp=$(mktemp "${directory}/.${PROGRAM}.XXXXXX") ||
        die "Cannot create temporary file beside $destination."

    echo "$tmp"
}

# ----------------------------------------------------------------------
# Generate nftables rules.
# ----------------------------------------------------------------------

generate_rules() {
    cat <<'NFT'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    chain input {
        type filter hook input priority 0;
        policy drop;

        # --------------------------------------------------------------
        # Localhost
        # --------------------------------------------------------------
        iif lo accept

        # --------------------------------------------------------------
        # Replies to connections initiated by this machine.
        # --------------------------------------------------------------
        ct state established,related accept

        # --------------------------------------------------------------
        # DHCPv4 client.
        #
        # DHCP server replies:
        #   UDP source port 67 -> destination port 68
        # --------------------------------------------------------------
        ip protocol udp udp sport 67 udp dport 68 accept

        # --------------------------------------------------------------
        # DHCPv6 client.
        #
        # DHCPv6 server replies:
        #   UDP source port 547 -> destination port 546
        # --------------------------------------------------------------
        ip6 nexthdr udp udp sport 547 udp dport 546 accept

        # --------------------------------------------------------------
        # IPv6 Neighbor Discovery and Router Advertisements.
        #
        # Required for ordinary IPv6 client operation, including SLAAC
        # and neighbor discovery.
        # --------------------------------------------------------------
        icmpv6 type {
            nd-router-advert,
            nd-neighbor-solicit,
            nd-neighbor-advert
        } accept

        # --------------------------------------------------------------
        # Essential ICMPv6 error messages.
        #
        # These are important for IPv6 Path MTU Discovery and for
        # reporting unreachable or expired traffic.
        # --------------------------------------------------------------
        icmpv6 type {
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem
        } accept
    }

    # This helper is intended for a workstation, not a router.
    chain forward {
        type filter hook forward priority 0;
        policy drop;
    }

    # The workstation is allowed to initiate connections freely.
    chain output {
        type filter hook output priority 0;
        policy accept;
    }
}
NFT
}

# ----------------------------------------------------------------------
# Slackware startup script.
# ----------------------------------------------------------------------

generate_rc_firewall() {
    cat <<'RC'
#!/bin/sh

# Load the nftables workstation firewall.
/usr/sbin/nft -f /etc/nftables.conf
RC
}

# ----------------------------------------------------------------------
# Validate a candidate nftables configuration.
#
# This does NOT modify the currently active ruleset.
# ----------------------------------------------------------------------

validate_rules() {
    local candidate="$1"

    log ""
    log "Validating nftables configuration..."
    log ""

    if ! "$NFT" -c -f "$candidate"; then
        die "nftables configuration validation failed; nothing was installed."
    fi

    log "nftables configuration validation succeeded."
}

# ----------------------------------------------------------------------
# Install one file atomically.
# ----------------------------------------------------------------------

install_file() {
    local tmp="$1"
    local destination="$2"
    local mode="$3"

    chmod "$mode" "$tmp" ||
        die "Cannot set permissions on temporary file for $destination."

    chown root:root "$tmp" ||
        die "Cannot set ownership on temporary file for $destination."

    mv -f -- "$tmp" "$destination" ||
        die "Cannot install $destination."
}

# ----------------------------------------------------------------------
# Activate the firewall.
# ----------------------------------------------------------------------

activate_firewall() {
    log ""
    log "Activating nftables firewall..."
    log ""

    if ! "$NFT" -f "$NFTABLES_CONF"; then
        die "Failed to activate nftables firewall."
    fi

    log "nftables firewall activated."
}

# ----------------------------------------------------------------------
# Show the resulting ruleset.
# ----------------------------------------------------------------------

show_ruleset() {
    log ""
    log "Current ruleset:"
    log ""

    "$NFT" list ruleset ||
        die "Could not display the active nftables ruleset."
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

main() {
    require_root

    command_exists "$NFT" ||
        die "$NFT not found; is nftables installed?"

    [[ -x "$NFT" ]] ||
        die "$NFT exists but is not executable."

    [[ -d /etc ]] ||
        die "/etc does not exist."

    [[ -d /etc/rc.d ]] ||
        die "/etc/rc.d does not exist; this does not appear to be a normal Slackware installation."

    log ""
    log "============================================================"
    log " $PROGRAM $VERSION"
    log "============================================================"
    log ""
    log "Installing a very basic dual-stack nftables workstation firewall."
    log ""
    log "Policy:"
    log "    INPUT    DROP"
    log "    FORWARD  DROP"
    log "    OUTPUT   ACCEPT"
    log ""
    log "Permitted inbound traffic:"
    log "    loopback"
    log "    established/related traffic"
    log "    DHCPv4 replies"
    log "    DHCPv6 replies"
    log "    required IPv6 Neighbor Discovery traffic"
    log "    essential ICMPv6 errors"
    log ""

    # ------------------------------------------------------------------
    # Generate the candidate configuration without touching the live
    # configuration.
    # ------------------------------------------------------------------

    TMP_RULES=$(make_temp_file "$NFTABLES_CONF")

    if ! generate_rules > "$TMP_RULES"; then
        die "Could not generate nftables configuration."
    fi

    chmod 0644 "$TMP_RULES" ||
        die "Cannot set permissions on temporary nftables configuration."

    chown root:root "$TMP_RULES" ||
        die "Cannot set ownership on temporary nftables configuration."

    # ------------------------------------------------------------------
    # Validate before backing up or replacing anything.
    # ------------------------------------------------------------------

    validate_rules "$TMP_RULES"

    # ------------------------------------------------------------------
    # Generate the rc.firewall candidate.
    # ------------------------------------------------------------------

    TMP_RC=$(make_temp_file "$RC_FIREWALL")

    if ! generate_rc_firewall > "$TMP_RC"; then
        die "Could not generate rc.firewall."
    fi

    chmod 0755 "$TMP_RC" ||
        die "Cannot set permissions on temporary rc.firewall."

    chown root:root "$TMP_RC" ||
        die "Cannot set ownership on temporary rc.firewall."

    # ------------------------------------------------------------------
    # Preserve existing files.
    # ------------------------------------------------------------------

    log ""
    log "Creating backups..."
    log ""

    backup_file "$NFTABLES_CONF"
    backup_file "$RC_FIREWALL"

    # ------------------------------------------------------------------
    # Install nftables.conf.
    # ------------------------------------------------------------------

    log ""
    log "Installing $NFTABLES_CONF..."

    install_file "$TMP_RULES" "$NFTABLES_CONF" 0644
    TMP_RULES=''

    # ------------------------------------------------------------------
    # Install rc.firewall.
    # ------------------------------------------------------------------

    log "Installing $RC_FIREWALL..."

    install_file "$TMP_RC" "$RC_FIREWALL" 0755
    TMP_RC=''

    # ------------------------------------------------------------------
    # Activate the firewall immediately.
    # ------------------------------------------------------------------

    activate_firewall

    # ------------------------------------------------------------------
    # Final verification.
    # ------------------------------------------------------------------

    show_ruleset

    SUCCESS=1

    log ""
    log "============================================================"
    log " Firewall installation complete"
    log "============================================================"
    log ""
    log "Configuration : $NFTABLES_CONF"
    log "Startup script : $RC_FIREWALL"
    log ""
    log "The firewall permits outbound connections and the traffic"
    log "required for DHCP and normal IPv6 client configuration."
    log ""
    log "This helper is intended for a simple workstation."
    log "It is not a general-purpose firewall configuration tool."
    log ""
}

main "$@"
