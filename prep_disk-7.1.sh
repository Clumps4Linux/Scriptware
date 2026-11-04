#!/bin/bash
# prep_disk.sh - Slackware encrypted-Btrfs disk preparation/finalization helper
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
#
# Unified Slackware disk preparation/finalization helper.
#
# Stage 1:
#
#     CURRENT IMPLEMENTATION (single-layout mode):
#         GPT
#         ├── p1: 1 GiB EFI System Partition
#         └── p2: remaining disk, LUKS2
#             └── Btrfs (direct, no LVM)
#                 ├── @
#                 └── @home
#
#     FUTURE EXTENSIONS (multi-layout mode - TODO):
#         GPT
#         ├── p1: configurable ESP size (256MiB–1GiB)
#         └── p2+: configurable partitions
#             └── Optional LUKS2 layer
#                 └── Optional LVM VG
#                     └── Optional swap LV
#                     └── Btrfs/XFS/ext4 logical volumes
#
#     NOTE ON DESIGN PHILOSOPHY: Even in its ultimate form, this script is
#     not intended to be infinitely flexible. Some opinionated choices will
#     always be made to maintain coherence and avoid configuration hell.
#     Examples include swap sizing rules (see below) and ZSWAP/ZRAM mutual
#     exclusion. The goal is a usable system, not a generic framework.
#
# Stage 2:
#
#     - Detect preparation metadata on the ESP.
#     - Verify the exact disk/partition/storage stack.
#     - Open LUKS2 if necessary.
#     - Verify Btrfs and required subvolumes.
#     - Mount the installed target.
#     - Merge only helper-managed fstab/crypttab blocks.
#     - Generate/repair the installed initrd with mkinitrd when it is
#       missing or cannot reach the prepared LUKS/Btrfs root.
#     - Ensure installed kernel/initrd exist on the ESP.
#     - Verify that the kernel can be used as a UEFI EFI-stub image.
#     - Create/update a direct UEFI firmware boot-menu entry for the kernel.
#     - Verify the kernel, initrd and UEFI entry before succeeding.
#     - Create read-only initial Btrfs snapshots (when Btrfs selected).
#     - FUTURE: optionally enable firewall scripts before first snapshots.
#
# ----------------------------------------------------------------------
#
# BOOT DESIGN (current and future):
#
#     This helper does NOT install or configure a traditional bootloader.
#
#     It does NOT invoke:
#
#         lilo
#         elilo
#         grub-install
#         grub-mkconfig
#
#     Instead, the Linux kernel itself is loaded directly by UEFI firmware
#     through the kernel's EFI stub interface.
#
#     The helper therefore:
#
#         0. generates the installed initrd with mkinitrd when the
#            installed system has none, or when the existing one cannot
#            reach the prepared LUKS/Btrfs root;
#         1. copies the kernel to the ESP;
#         2. copies the initrd to the ESP;
#         3. creates a UEFI NVRAM Boot#### entry with efibootmgr;
#         4. points that entry directly at the kernel;
#         5. passes the initrd and Slackware root parameters to the kernel;
#         6. verifies the kernel, initrd and BootOrder before succeeding.
#
#     This is intentional.  The working boot method for this installation is
#     direct firmware -> EFI-stub-kernel boot, without LILO, ELILO, or GRUB.
#
#     IMPORTANT: Initrd Verification Requirement (from repair-crypt-boot.sh):
#
#         The Slackware installer's mkinitrd expects certain storage stacks
#         and generates corresponding hooks. If the prep_disk storage layout
#         differs from what mkinitrd assumes, boot will fail with repeated
#         LUKS passphrase prompts or device-not-found errors.
#
#         IMPLEMENTED IN STAGE 2:
#
#         1. Before finalization succeeds, the installed initrd is inspected:
#              - luksdev      (must describe the encrypted root partition)
#              - rootdev      (must name a device Slackware's init will create)
#              - rootfs       (must match the actual filesystem type)
#
#            If the initrd is missing, or fails those checks, Stage 2
#            regenerates it with explicit mkinitrd flags first.
#
#         2. crypttab and the kernel command line are written to match the
#            mapper name Slackware's init script will derive.
#
#     Because a selectable firmware boot-menu entry is stored in EFI NVRAM,
#     finalization necessarily uses efibootmgr and modifies EFI NVRAM.
#
#     This is different from installing a bootloader:
#
#         UEFI firmware
#             |
#             +--> Linux kernel EFI stub
#                       |
#                       +--> initrd
#                               |
#                               +--> /dev/mapper/<LUKS_NAME>
#                                       |
#                                       +--> [Optional LVM]
#                                               |
#                                               +--> Btrfs subvolume @
#
# ----------------------------------------------------------------------
#
# CURRENT LIMITATIONS AND FUTURE ENHANCEMENT ROADMAP:
#
# 1. STORAGE STACK TO BE MADE SELECTABLE:
#
#    Current:     LUKS2 → Btrfs (direct, no LVM)
#    Future:      Allow choice between:
#                 - LUKS2 → Btrfs (direct)
#                 - LUKS2 → LVM → Btrfs (recommended for Slackware compatibility)
#                 - LUKS2 → Btrfs → swap file (no swap partition)
#                 - Unencrypted variants for testing
#
#    Rationale:   The repair-crypt-boot.sh script proves Slackware's default
#                 initrd generation expects LVM. Removing LVM breaks implicit
#                 assumptions in mkinitrd. The current version handles this
#                 by forcing initrd regeneration with explicit no-LVM flags.
#
# 2. SWAP HANDLING:
#
#    Current:     No swap created (Slackware current sets up zRAM in setup)
#    Future:      Option to create dedicated swap LV/partition
#
#    SWAP SIZING RULE (OPINIONATED CHOICE):
#                 When swap partitions/LVs are created, they will be sized
#                 to match installed physical RAM, up to a maximum of 8 GB.
#                 This balances hibernation support with avoiding excessive
#                 disk allocation on systems with large RAM.
#
#    ZSWAP POLICY (OPINIONATED CHOICE):
#                 If swap partitions/LVs are used, ZSWAP will be enabled
#                 with default kernel options. This compresses swapped pages
#                 before writing to swap device, improving performance.
#
#                 CRITICAL MUTUAL EXCLUSION: ZSWAP must NOT be enabled if
#                 the default ZRAM swap mechanism is active. ZRAM already
#                 provides compressed RAM-based swap; enabling ZSWAP on top
#                 would be redundant and potentially harmful. Future versions
#                 must detect zRAM usage and disable ZSWAP accordingly, or
#                 vice versa.
#
#    SWAP ENCRYPTION (OPINIONATED CHOICE):
#                 ALL swap devices MUST be encrypted, regardless of whether
#                 root filesystem encryption (FDE) is chosen.
#              
#                 This ensures that suspended session data, swap pages
#                 containing sensitive memory dumps, and cryptographic keys
#                 never reside unencrypted on persistent storage.
#              
#              Implementation options:
#
#                (a) With FDE + LVM (recommended):
#                    - Swap LV resides within encrypted volume group
#                    - Same LUKS container as root
#                    - Single passphrase unlocks both root and swap
#                    - Minimal initrd complexity
#
#                (b) Without FDE, or with separate swap encryption:
#                    - Dedicated LUKS container for swap only
#                    - Independent encryption layer
#                    - Separate keyslot or keyfile management
#                    - Initrd must include LUKS hook for swap device
#
#              Plaintext swap is explicitly unsupported and will be
#              rejected by the script. This policy cannot be overridden.
#
#              Rationale:
#                - Prevents recovery of sensitive data from swap media
#                - Required for secure hibernation support
#                - Maintains confidentiality even on systems without FDE
#                - Aligns with security-conscious user base expectations
#
# 3. FILESYSTEM OPTIONS:
#
#    Current:     Btrfs fixed with XXHASH + zstd compression + @/@home subvolumes
#    Future:      Allow choice of:
#                 - Btrfs (with optional subvolume layout, checksum algo)
#                 - ext4, XFS (if initrd hooks available)
#                 - When Btrfs selected: always use XXHASH, zstd, @/@home,
#                   and create initial read-only snapshots
#
# 4. LUKS VERSION:
#
#    Current:     LUKS2 forced
#    Future:      Keep LUKS2 default, optionally allow LUKS1 for legacy testing
#
# 5. CRYPTTAB/INITRD SYNCHRONIZATION:
#
#    Critical lesson from repair-crypt-boot.sh:
#
#    The triple passphrase prompt failure occurred because:
#      - crypttab had one LUKS mapper name
#      - initrd's luksdev file had another
#      - initrd's rootdev referenced a third (LVM path vs direct path)
#
#    Stage 2 now does:
#      a) Ensure crypttab LUKS name matches the initrd's luksdev
#      b) Ensure kernel root= parameter matches the initrd's rootdev
#      c) When LVM is used, ensure rootdev points to LV not PV
#      d) When regenerating the initrd, pass explicit -r (root), -C (luks),
#         -f (filesystem) and -m (module) flags matching the actual stack
#
# 6. FIREWALL SCRIPT INTEGRATION:
#
#    Future:      Option to enable one of several simple firewall scripts
#                 BEFORE creating the first read-only Btrfs snapshots.
#                 This ensures the baseline system state includes network
#                 security hardening before snapshotting. Snapshots created
#                 afterward represent a hardened baseline.
#
# 7. METADATA PERSISTENCE:
#
#    Current:     Stores prep config in /boot/efi/EFI/Slackware/prep_disk/
#    Future:      Same, but ensure installer doesn't overwrite this directory
#                 Consider backing up to separate location
#
# ----------------------------------------------------------------------

# =============================================================================
# VERSION HISTORY
# =============================================================================
# 
# Original implementation: Perl (v1.0)
# Current implementation:  Bash (v2.0-bash - v7.1.1-bash)
#
# 7.1.1-bash (2026-11-03):
#   - Stage 2 generates/repairs the installed initrd with explicit
#     mkinitrd flags when it is missing or cannot reach the prepared
#     LUKS/Btrfs root.
#   - Stage 2 verifies the kernel, initrd and UEFI Boot####/BootOrder
#     entry before reporting success.
#   - Added --make-installer: mirrors Slackware-current, embeds prep_disk
#     in the installer initrd at /usr/lib/setup/prep_disk (on PATH like
#     "setup"), and builds a hybrid USB image with a PREPUSB partition.
#   - Fixed a read-only ESP mount left behind by metadata detection.
#
# Converted from Perl because Slackware installer lacks Perl interpreter. Oops.
# See: https://slackware.com/current/packages.php (base-install category)
#
# PROJECT EVOLUTION NOTES:
# This project began simply as an automation tool for setting up a BTRFS
# filesystem with modern options (compression, checksums, subvolumes) and
# full-disk encryption (LUKS2). Over time, the scope expanded significantly.
#
# The vision is now to make this a more general-purpose pre and post-setup
# script, not exclusively dealing with disk preparation. Examples include:
#   - Enabling firewall configurations before first snapshots
#   - Post-install hardening steps
#   - General system baseline creation
#
# Despite this expansion, opinionated design choices remain intentional.
# Not every possible configuration will ever be supported—the goal is
# a coherent, well-tested path forward, not infinite flexibility.
#
# =============================================================================

# =============================================================================
# FUTURE ARCHITECTURE: MODULAR BREAKDOWN
# =============================================================================
#
# Upon stabilization of v7.x, this monolithic script will be refactored into
# independent helper modules. The orchestrator (this file) will delegate
# responsibility to specialized scripts, while preserving the opinionated
# policy decisions documented above.
#
# DESIGN PRINCIPLES:
#   - Modularity improves testability and maintainability
#   - Modules are reusable across different workflows (not just disk prep)
#   - Opinionated policies remain enforced at the orchestration layer
#   - No path leads to insecure defaults (e.g., plaintext swap)
#
# MODULE LAYOUT (future directory structure):
#
#   /usr/lib/prep_disk/modules/
#   ├── prep_partition.sh       # GPT table creation, partition sizing
#   ├── prep_luks2.sh           # LUKS2 format, open, mapper verification
#   ├── prep_btrfs.sh           # mkfs.btrfs, subvolume creation
#   ├── prep_xfs.sh             # Alternative filesystem (future)
#   ├── prep_ext4.sh            # Alternative filesystem (future)
#   ├── prep_swap.sh            # Swap LV/partition, encryption, sizing policy
#   ├── prep_zram.sh            # zRAM configuration (Slackware default)
#   ├── prep_zswap.sh           # Kernel ZSWAP enable/disable logic
#   ├── prep_firewall.sh        # Firewall script integration (nftables/iptables)
#   ├── prep_uefi_boot.sh       # efibootmgr, kernel/initrd to ESP
#   ├── prep_metadata.sh        # Read/write/validate preparation metadata
#   ├── prep_config_merge.sh    # fstab/crypttab block insertion
#   └── prep_snapshots.sh       # Read-only Btrfs snapshot creation
#
# EXECUTION ORDER (Phase 1: Preparation - destructive):
#
#   1. prep_partition.sh       → GPT, ESP, root partition
#   2. prep_luks2.sh           → Format root partition (optional for non-FDE)
#   3. prep_btrfs.sh (or ext4/XFS) → Format inside LUKS or direct
#   4. prep_swap.sh            → Create encrypted swap (required if not zRAM)
#                              → Sizing: RAM-matched, max 8GB, always encrypted
#   5. Mount target filesystems
#   6. Proceed to Slackware installer
#
# EXECUTION ORDER (Phase 2: Finalization - post-install):
#
#   7. prep_metadata.sh        → Validate existing preparation metadata
#   8. prep_luks2.sh           → Verify/open LUKS containers
#   9. prep_btrfs.sh           → Mount correct subvolumes
#   10. prep_swap.sh           → Verify swap device presence/encryption
#   11. prep_config_merge.sh   → Update fstab/crypttab managed blocks
#   12. prep_uefi_boot.sh      → Copy kernel/initrd, create NVRAM entry
#   13. prep_firewall.sh       → Install firewall BEFORE snapshots (optional)
#   14. prep_snapshots.sh      → Create baseline read-only snapshots
#
# POLICY ENFORCEMENT STRATEGY:
#
#   Even after modularization, opinionated choices remain enforced:
#
#   - SWAP SIZING:         RAM-matched, max 8GB (cannot be bypassed easily)
#   - SWAP ENCRYPTION:     Mandatory, no plaintext swap (policy flag only for override)
#   - ZSWAP/ZRAM:          Mutually exclusive (auto-detect, disable conflicting)
#   - FIREWALL:            Only curated scripts supported (firestarter.nftables)
#   - BOOT METHOD:         Direct UEFI EFI-stub kernel (no LILO/GRUB)
#
#   The orchestrator validates module outputs against these rules before
#   allowing progression. Failed validations halt with clear errors.
#
# DEPENDENCY GRAPH:
#
#     prep_partition.sh
#            ↓
#     prep_luks2.sh ───→ (optional for non-FDE builds)
#            ↓
#     prep_btrfs.sh ────┬────→ prep_xfs.sh / prep_ext4.sh (mutual exclusives)
#            ↓          │
#     prep_swap.sh      │      (swap always encrypted, FDE or standalone)
#            ↓          │
#     [SLACKWARE INSTALL]     (external process between phases)
#            ↓          │
#     prep_config_merge.sh
#            ↓          │
#     prep_uefi_boot.sh │
#            ↓          │
#     prep_firewall.sh  │      (runs BEFORE snapshots if enabled)
#            ↓          │
#     prep_snapshots.sh │
#
# BACKWARD COMPATIBILITY PLAN:
#
#   Phase 1 (v7.x): Monolith + new modules in parallel
#     - Both code paths exist
#     - USE_MODULES=1 env var selects new system
#     - Deprecation warnings on legacy mode
#
#   Phase 2 (v8.0): Modules primary, monolith legacy
#     - Default to module system
#     - Legacy mode requires explicit opt-in
#     - Migration guide published
#
#   Phase 3 (v9.0): Modules only
#     - Legacy mode removed
#     - Full module API documentation
#
# MIGRATION CONSIDERATIONS:
#
#   - Metadata schema must remain stable across both versions
#   - Module scripts must produce identical outcomes to legacy functions
#   - Test coverage expands per-module (CI exercises all combinations)
#   - Cleanup/rollback logic centralized in orchestrator
#
# =============================================================================

set -euo pipefail

PROGRAM='prep_disk.sh'
VERSION='7.1.1-bash'

# ============================================================
# CONSTANTS
# ============================================================

# =============================================================================
# FUTURE ENHANCEMENT TODO:
#
# Make these constants configurable via:
#   - Command-line arguments (--esp-size, --fs-type, --lvm-enabled, etc.)
#   - Interactive prompts during Stage 1
#   - Pre-generated config file
#
# Example interface:
#   ./prep_disk.sh /dev/sda --esp-size=1G --enable-lvm --swap-size=4G
#   ./prep_disk.sh /dev/nvme0n1 --no-encryption --fs=ext4
# =============================================================================

PREP_DIR='EFI/Slackware/prep_disk'

ESP_TYPE_GUID='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'

# =============================================================================
# ROOT_TYPE_GUID is the standard "Linux LUKS" GPT type (the GUID form of
# sgdisk's 8309 alias).  It is not a custom type.
# =============================================================================

ROOT_TYPE_GUID='ca7d7bbb-63ed-4c53-861c-1742536059cc'

# sgdisk understands the binary K/M/G/T suffixes directly.  1G here means
# 1 GiB, matching the documented ESP size.
ESP_SIZE='1G'

# =============================================================================
# FUTURE ENHANCEMENT TODO:
#
# LUKS mapper name affects crypttab and initrd synchronization.
# From repair-crypt-boot.sh: cryptlvm worked; changing to luksmmcblk0p2 fixed
# triple-prompt boot loop. The key is consistency across:
#   1. cryptsetup open name
#   2. /etc/crypttab first field
#   3. initrd's luksdev file content
#   4. Kernel root= parameter (if LVM: /dev/mapper/VG-LV; if direct: /dev/mapper/NAME)
#
# Recommended approach for future:
#   - If LVM enabled: use consistent naming (e.g., cryptvg, then logical volumes)
#   - If no LVM: use luks<device> (Slackware's initrd convention)
#   - ALWAYS verify initrd luksdev after creation
#   - Consider making name configurable but enforcing documentation
# =============================================================================

# Install-time LUKS mapper name.  Slackware's initrd derives the boot-time
# name as luks<basename(encrypted device)>, so using the same convention in
# Stage 1 keeps installation-time and boot-time names aligned.
LUKS_NAME=''

# The boot-time LUKS mapper name is not necessarily the install-time name.
# Slackware's initrd chooses the mapper name itself (see SLACKWARE INITRD
# NAMING below).  Stage 2 derives this from the installed initrd and writes
# /etc/crypttab so that rc.luks does not try to open the device a second time.
BOOT_LUKS_NAME=''

# Facts read from the installed initrd during Stage 2.
INITRD_ROOTDEV=''
INITRD_LUKSDEV=''
INITRD_ROOTFS=''
KERNEL_SOURCE=''
INITRD_SOURCE=''

# Temporary copy of the metadata file used while the ESP is mounted only
# for detection.  Removed by cleanup.
METADATA_TMP=''

BTRFS_ROOT_SUBVOL='@'
BTRFS_HOME_SUBVOL='@home'

BTRFS_CHECKSUM='xxhash'

UEFI_BOOT_LABEL='Slackware direct kernel'

MOUNT_ROOT='/run/prep_disk_root'
MOUNT_ESP='/run/prep_disk_esp'
MOUNT_TOP='/run/prep_disk_top'

TARGET_ROOT='/mnt'
TARGET_ESP='/mnt/boot/efi'

DRY_RUN=0
FORCE_PREPARE=0

# ------------------------------------------------------------------
# Installer-image builder (--make-installer)
#
# This mode runs on a normal Linux host, not inside the installer.  It
# mirrors Slackware-current, installs this helper into the installer
# initrd (at /usr/lib/setup/prep_disk, on PATH exactly like "setup"),
# and assembles a hybrid USB image with a PREPUSB package partition.
# ------------------------------------------------------------------
MAKE_INSTALLER=0
SELF=$(readlink -f -- "$0" 2>/dev/null || printf '%s\n' "$0")
B_MIRROR='https://mirror.us.leaseweb.net/slackware/slackware64-current/'
B_WORKDIR=''
B_OUTPUT=''
B_SERIES=''
B_SIZE='auto'
B_DEVICE=''
B_ISO_ONLY=0
B_NO_RSYNC=0
B_VERIFY=0
B_KEEP=0
B_FORCE=0

declare -A CFG=()

declare -a CREATED_MOUNTS=()
declare -a CREATED_SNAPSHOTS=()

LUKS_OPENED_BY_US=0
SUCCESS=0

# ============================================================
# LOGGING
# ============================================================

log() {
    printf '%s\n' "$*"
}

log_cmd() {
    printf '>>>'
    printf ' %q' "$@"
    printf '\n'
}

die() {
    printf '\nERROR: %s\n\n' "$*" >&2
    cleanup
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================
# COMMAND EXECUTION
# ============================================================

run_cmd() {
    log_cmd "$@"

    if (( DRY_RUN )); then
        return 0
    fi

    "$@" || die "Command failed: $(printf '%q ' "$@")"
}

# ============================================================
# FILE HELPERS
# ============================================================

write_file() {
    local path="$1"
    local contents="$2"
    local mode="${3:-0644}"

    (( DRY_RUN )) && return 0

    mkdir -p "$(dirname "$path")"

    local tmp="${path}.tmp.$$"

    printf '%s\n' "$contents" > "$tmp"
    chmod "$mode" "$tmp"
    mv -f -- "$tmp" "$path"
}

backup_file() {
    local path="$1"

    [[ -f "$path" ]] || return 0

    local stamp
    stamp=$(date '+%Y%m%d-%H%M%S')

    local backup="${path}.prep_disk.${stamp}"
    local suffix=1

    while [[ -e "$backup" ]]; do
        backup="${path}.prep_disk.${stamp}.${suffix}"
        (( suffix++ ))
    done

    log "Backing up:"
    log "    $path"
    log " -> $backup"

    (( DRY_RUN )) && return 0

    cp -a -- "$path" "$backup"
}

read_required_file() {
    local path="$1"
    local description="$2"

    [[ -f "$path" ]] ||
        die "$description not found: $path"

    cat -- "$path"
}

# ============================================================
# USER INPUT
# ============================================================

prompt_password() {
    local prompt="${1:-Password: }"
    local old_stty=''
    local password=''

    old_stty=$(stty -g 2>/dev/null || true)

    printf '%s' "$prompt" >&2
    stty -echo 2>/dev/null || true

    IFS= read -r password

    printf '\n' >&2

    if [[ -n "$old_stty" ]]; then
        stty "$old_stty" 2>/dev/null || true
    fi

    printf '%s' "$password"
}

confirm_yes() {
    local question="$1"
    local answer=''

    printf '%s [type YES]: ' "$question" >&2
    IFS= read -r answer

    [[ "$answer" == 'YES' ]]
}

# ============================================================
# MOUNT HELPERS
# ============================================================

is_mounted() {
    # --mountpoint checks that this exact path is a mountpoint.  --target
    # would also succeed for any directory merely contained in a mount.
    findmnt -rn --mountpoint "$1" >/dev/null 2>&1
}

mount_source() {
    local source

    source=$(findmnt -rn -o SOURCE --mountpoint "$1" 2>/dev/null || true)

    # Newer util-linux appends the Btrfs subvolume to SOURCE, for example
    # /dev/mapper/root[/@].  Compare only the device portion.
    printf '%s\n' "${source%%[*}"
}

resolve_device_path() {
    readlink -f -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

same_device() {
    local a="$1"
    local b="$2"

    [[ -n "$a" && -n "$b" ]] || return 1

    [[ "$(resolve_device_path "$a")" == "$(resolve_device_path "$b")" ]]
}

mount_fstype() {
    findmnt -rn -o FSTYPE --mountpoint "$1" 2>/dev/null || true
}

mount_options() {
    findmnt -rn -o OPTIONS --mountpoint "$1" 2>/dev/null || true
}

mount_option_contains() {
    local options="$1"
    local wanted="$2"
    local old_ifs="$IFS"

    IFS=','
    local option

    for option in $options; do
        if [[ "$option" == "$wanted" ]]; then
            IFS="$old_ifs"
            return 0
        fi
    done

    IFS="$old_ifs"
    return 1
}

record_mount() {
    local target="$1"

    local existing
    for existing in "${CREATED_MOUNTS[@]}"; do
        [[ "$existing" == "$target" ]] && return 0
    done

    CREATED_MOUNTS+=("$target")
}

mount_is_owned() {
    local target="$1"
    local existing

    for existing in "${CREATED_MOUNTS[@]}"; do
        [[ "$existing" == "$target" ]] && return 0
    done

    return 1
}

forget_mount() {
    local target="$1"
    local existing
    local -a remaining=()

    for existing in "${CREATED_MOUNTS[@]}"; do
        [[ "$existing" == "$target" ]] || remaining+=("$existing")
    done

    CREATED_MOUNTS=("${remaining[@]}")
}

verify_esp_mount() {
    local target="$1"
    local expected="$2"

    is_mounted "$target" ||
        die "$target is not mounted."

    [[ "$(mount_fstype "$target")" == 'vfat' ]] ||
        die "$target is not a vfat filesystem."

    local actual
    actual=$(mount_source "$target")

    same_device "$actual" "$expected" ||
        die "Wrong filesystem mounted at $target. Expected $expected, got ${actual:-none}."
}

verify_btrfs_mount() {
    local target="$1"
    local expected_device="$2"
    local expected_subvol="$3"

    is_mounted "$target" ||
        die "$target is not mounted."

    [[ "$(mount_fstype "$target")" == 'btrfs' ]] ||
        die "$target is not Btrfs."

    local actual
    actual=$(mount_source "$target")

    same_device "$actual" "$expected_device" ||
        die "Wrong filesystem mounted at $target. Expected $expected_device, got ${actual:-none}."

    local options
    options=$(mount_options "$target")

    # findmnt commonly reports the subvolume as "subvol=/@" (newer kernels)
    # while older util-linux versions report "subvol=@".
    mount_option_contains "$options" "subvol=$expected_subvol" ||
        mount_option_contains "$options" "subvol=/$expected_subvol" ||
        die "Wrong Btrfs subvolume at $target. Expected subvol=$expected_subvol. Options: $options"
}

mount_esp() {
    local partition="$1"
    local target="$2"

    mkdir -p "$target"

    if is_mounted "$target"; then
        verify_esp_mount "$target" "$partition"
        return 0
    fi

    run_cmd mount -t vfat "$partition" "$target"
    record_mount "$target"
}

mount_btrfs_subvol() {
    local mapper="$1"
    local subvol="$2"
    local target="$3"

    mkdir -p "$target"

    if is_mounted "$target"; then
        verify_btrfs_mount "$target" "$mapper" "$subvol"
        return 0
    fi

    run_cmd mount \
        -t btrfs \
        -o "subvol=$subvol,compress=zstd" \
        "$mapper" \
        "$target"

    record_mount "$target"
}

mount_btrfs_top() {
    local mapper="$1"

    mkdir -p "$MOUNT_TOP"

    if is_mounted "$MOUNT_TOP"; then
        die "$MOUNT_TOP is already mounted."
    fi

    run_cmd mount \
        -t btrfs \
        -o subvolid=5 \
        "$mapper" \
        "$MOUNT_TOP"

    record_mount "$MOUNT_TOP"
}

mount_prepared_target() {
    local mapper="$1"
    local root_subvol="$2"
    local home_subvol="$3"
    local esp="$4"

    mount_btrfs_subvol \
        "$mapper" \
        "$root_subvol" \
        "$TARGET_ROOT"

    mount_btrfs_subvol \
        "$mapper" \
        "$home_subvol" \
        "${TARGET_ROOT}/home"

    mount_esp \
        "$esp" \
        "$TARGET_ESP"
}

verify_prepared_target() {
    local mapper="$1"
    local root_subvol="$2"
    local home_subvol="$3"
    local esp="$4"

    verify_btrfs_mount \
        "$TARGET_ROOT" \
        "$mapper" \
        "$root_subvol"

    verify_btrfs_mount \
        "${TARGET_ROOT}/home" \
        "$mapper" \
        "$home_subvol"

    verify_esp_mount \
        "$TARGET_ESP" \
        "$esp"
}

# ============================================================
# DEVICE HELPERS
# ============================================================

partition_path() {
    local disk="$1"
    local number="$2"

    case "$disk" in
        /dev/nvme[0-9]*n[0-9]*)
            printf '%sp%s\n' "$disk" "$number"
            ;;
        /dev/mmcblk[0-9]*)
            printf '%sp%s\n' "$disk" "$number"
            ;;
        /dev/loop[0-9]*)
            printf '%sp%s\n' "$disk" "$number"
            ;;
        /dev/md[0-9]*)
            printf '%sp%s\n' "$disk" "$number"
            ;;
        *)
            printf '%s%s\n' "$disk" "$number"
            ;;
    esac
}

block_type() {
    lsblk -dnro TYPE "$1" 2>/dev/null |
        tr -d '[:space:]' || true
}

partition_uuid() {
    blkid -s UUID -o value "$1" 2>/dev/null |
        tr -d '[:space:]' || true
}

partition_type_guid() {
    # blkid -s PART_ENTRY_TYPE is not reliable in the installer environment
    # (it can return empty until a filesystem exists).  lsblk reads the GPT
    # entry directly.
    lsblk -dnro PARTTYPE "$1" 2>/dev/null |
        tr -d '[:space:]' |
        tr '[:upper:]' '[:lower:]' || true
}

luks_uuid() {
    cryptsetup luksUUID "$1" 2>/dev/null |
        tr -d '[:space:]' || true
}

btrfs_uuid() {
    blkid -s UUID -o value "$1" 2>/dev/null |
        tr -d '[:space:]' || true
}

valid_uuid() {
    [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

valid_vfat_uuid() {
    [[ "$1" =~ ^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$ ]]
}

# ============================================================
# DISK VALIDATION
# ============================================================

validate_disk_argument() {
    local device="$1"
    [[ "$device" == /dev/* ]] ||
        die "Device must be under /dev."

    [[ "$device" != *$'\n'* &&
       "$device" != *$'\r'* &&
       "$device" != *';'* &&
       "$device" != *'|'* &&
       "$device" != *'&'* &&
       "$device" != *'<'* &&
       "$device" != *'>'* &&
       "$device" != *'$('* &&
       "$device" != *'`'* ]] ||
        die "Suspicious device name rejected: $device"

    [[ -b "$device" ]] ||
        die "Device does not exist: $device"

    [[ "$(block_type "$device")" == 'disk' ]] ||
        die "$device is not a whole-disk block device."
}

set_luks_name() {
    local disk="$1"
    local root

    root=$(partition_path "$disk" 2)
    LUKS_NAME="luks$(basename "$root")"

    [[ "$LUKS_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] ||
        die "Could not derive a safe LUKS mapper name for $root."
}

verify_partition_layout() {
    local disk="$1"
    local esp="$2"
    local root="$3"

    [[ -b "$disk" ]] || die "Disk does not exist: $disk"
    [[ -b "$esp" ]] || die "ESP does not exist: $esp"
    [[ -b "$root" ]] || die "Root partition does not exist: $root"

    [[ "$(block_type "$disk")" == 'disk' ]] ||
        die "$disk is not a whole disk."

    [[ "$(partition_type_guid "$esp")" == "$ESP_TYPE_GUID" ]] ||
        die "Unexpected ESP GPT type."

    [[ "$(partition_type_guid "$root")" == "$ROOT_TYPE_GUID" ]] ||
        die "Unexpected root GPT type."
}

disk_mount_report() {
    local disk="$1"

    lsblk -nrpo NAME,MOUNTPOINT "$disk" |
        awk '$2 != "" { print $1 " -> " $2 }'
}

disk_holder_report() {
    local disk="$1"

    lsblk -nrpo NAME,TYPE "$disk" |
        awk '$2 == "crypt" || $2 == "lvm" { print $1 " (" $2 ")" }'
}

disk_is_unmounted() {
    local disk="$1"

    [[ -z "$(disk_mount_report "$disk")" ]] &&
        [[ -z "$(disk_holder_report "$disk")" ]]
}

verify_disk_unmounted() {
    local disk="$1"

    local mounts
    mounts=$(disk_mount_report "$disk")

    [[ -z "$mounts" ]] ||
        die "The disk or one of its partitions is mounted:\n$mounts\n\nUnmount it before preparation."

    local holders
    holders=$(disk_holder_report "$disk")

    [[ -z "$holders" ]] ||
        die "The disk has active device-mapper holders:\n$holders\n\nClose them before preparation."
}

# ============================================================
# LUKS
# ============================================================

require_luks2() {
    local partition="$1"
    local dump
    local version

    dump=$(cryptsetup luksDump "$partition" 2>&1) ||
        die "$partition is not a valid LUKS container."

    version=$(awk '$1 == "Version:" { print $2; exit }' <<< "$dump")

    [[ "$version" == '2' ]] ||
        die "$partition is not LUKS2. Detected version: ${version:-unknown}"
}

mapper_exists() {
    [[ -b "/dev/mapper/$1" ]]
}

verify_mapper() {
    local partition="$1"
    local name="$2"
    local expected_uuid="$3"

    local mapper="/dev/mapper/$name"

    [[ -b "$mapper" ]] ||
        die "LUKS mapper does not exist: $mapper"

    local status
    status=$(cryptsetup status "$name" 2>&1) ||
        die "Could not inspect LUKS mapper $name."

    local actual_device
    actual_device=$(awk '$1 == "device:" { print $2; exit }' <<< "$status")

    same_device "$actual_device" "$partition" ||
        die "LUKS mapper points at $actual_device, expected $partition."

    local actual_uuid
    actual_uuid=$(luks_uuid "$partition")

    [[ "${actual_uuid,,}" == "${expected_uuid,,}" ]] ||
        die "LUKS UUID mismatch. Expected $expected_uuid, got $actual_uuid."
}

open_luks_with_password() {
    local partition="$1"
    local name="$2"
    local password="$3"

    [[ "$name" == "$LUKS_NAME" ]] ||
        die "Unexpected LUKS mapper name."

    [[ -n "$password" ]] ||
        die "LUKS password may not be empty."

    # No trailing newline: see the note in Stage 1's luksFormat call.
    printf '%s' "$password" |
        cryptsetup open \
            --type luks2 \
            --key-file - \
            "$partition" \
            "$name" ||
        die "cryptsetup open failed."

    LUKS_OPENED_BY_US=1
}

open_luks_interactive() {
    local partition="$1"
    local name="$2"

    (( DRY_RUN == 0 )) ||
        die "Cannot open LUKS during dry-run."

    local password
    password=$(prompt_password 'Enter LUKS2 password: ')

    open_luks_with_password \
        "$partition" \
        "$name" \
        "$password"

    unset password
}

# ============================================================
# BTRFS
# ============================================================

btrfs_checksum_type() {
    local device="$1"
    local output

    output=$(btrfs inspect-internal dump-super "$device" 2>/dev/null) ||
        return 1

    awk '
        $1 == "csum_type" {
            text=$0
            sub(/^.*\(/, "", text)
            sub(/\).*/, "", text)
            print tolower(text)
            exit
        }
    ' <<< "$output"
}

verify_btrfs() {
    local device="$1"
    local expected_uuid="$2"

    local actual_uuid
    actual_uuid=$(btrfs_uuid "$device")

    [[ -n "$actual_uuid" ]] ||
        die "Could not determine Btrfs UUID."

    [[ "${actual_uuid,,}" == "${expected_uuid,,}" ]] ||
        die "Btrfs UUID mismatch. Expected $expected_uuid, got $actual_uuid."

    local checksum
    checksum=$(btrfs_checksum_type "$device" || true)

    # btrfs inspect-internal reports the canonical name "xxhash64"; mkfs.btrfs
    # accepts the shorter alias "xxhash".  Normalize before comparing.
    case "$checksum" in
        xxhash|xxhash64) checksum='xxhash' ;;
    esac

    [[ "$checksum" == "$BTRFS_CHECKSUM" ]] ||
        die "Unexpected Btrfs checksum. Expected $BTRFS_CHECKSUM, got ${checksum:-unknown}."
}

btrfs_subvolume_exists() {
    local mountpoint="$1"
    local wanted="$2"

    btrfs subvolume list "$mountpoint" 2>/dev/null |
        awk -v wanted="$wanted" '$NF == wanted { found=1 } END { exit !found }'
}

verify_subvolume() {
    local mountpoint="$1"
    local subvol="$2"

    btrfs_subvolume_exists "$mountpoint" "$subvol" ||
        die "Required Btrfs subvolume does not exist: $subvol"
}

ensure_default_subvolume() {
    local mountpoint="$1"
    local subvol="$2"

    local subvol_id

    subvol_id=$(
        btrfs subvolume list "$mountpoint" 2>/dev/null |
            awk -v wanted="$subvol" '$NF == wanted { print $2; exit }'
    ) || die "Could not list Btrfs subvolumes on $mountpoint."

    [[ -n "$subvol_id" ]] ||
        die "Could not determine the subvolume ID of $subvol."

    log "Ensuring Btrfs default subvolume is $subvol (ID $subvol_id)."

    run_cmd btrfs subvolume set-default "$subvol_id" "$mountpoint"
}

verify_readonly_snapshot() {
    local path="$1"
    local flags

    flags=$(
        btrfs subvolume show "$path" 2>/dev/null |
            awk -F':' '
                $1 ~ /^[[:space:]]*Flags[[:space:]]*$/ {
                    value=$2
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                    print tolower(value)
                    exit
                }
            '
    ) || die "Could not inspect snapshot: $path"

    [[ "$flags" == *readonly* ]] ||
        die "Snapshot is not read-only: $path (flags: ${flags:-unknown})"
}

snapshot_name() {
    local source="$1"
    local stamp="$2"

    [[ "$source" == "$BTRFS_ROOT_SUBVOL" ||
       "$source" == "$BTRFS_HOME_SUBVOL" ]] ||
        die "Invalid snapshot source."

    [[ "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] ||
        die "Invalid snapshot timestamp."

    printf '%s.initial-%s\n' "$source" "$stamp"
}

# ============================================================
# PREPARATION METADATA
# ============================================================

metadata_path() {
    printf '%s/%s/prep-disk.conf\n' "$1" "$PREP_DIR"
}

parse_config() {
    local file="$1"

    [[ -f "$file" ]] ||
        die "Metadata file not found: $file"

    CFG=()

    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        # Trim leading/trailing whitespace.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue

        [[ "$line" =~ ^([A-Za-z0-9_]+)=(.*)$ ]] ||
            die "Malformed metadata line: $line"

        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        [[ ! -v "CFG[$key]" ]] ||
            die "Duplicate metadata key: $key"

        CFG["$key"]="$value"
    done < "$file"

    local required

    for required in \
        VERSION \
        DISK \
        ESP_PARTITION \
        ROOT_PARTITION \
        ESP_UUID \
        LUKS_UUID \
        BTRFS_UUID \
        LUKS_NAME \
        ROOT_SUBVOL \
        HOME_SUBVOL \
        BTRFS_CHECKSUM
    do
        [[ -v "CFG[$required]" ]] ||
            die "Metadata key missing: $required"

        [[ -n "${CFG[$required]}" ]] ||
            die "Metadata key is empty: $required"
    done
}

# =============================================================================
# FUTURE ENHANCEMENT TODO:
#
# Extended metadata keys for multi-layout support:
#
# Add these fields to CFG validation when implementing options:
#   - STORAGE_STACK: (LUKS2_ONLY, LUKS2_LVM, UNENCRYPTED)
#   - FILESYSTEM: (BTRFS, EXT4, XFS)
#   - HAS_SWAP: (true/false)
#   - SWAP_SIZE: (optional, e.g., 8G)
#   - SWAP_ENCRYPTED: (true/false)
#   - SWAP_SIZING_RULE: (RAM_MAPPED_8GB_MAX, CUSTOM)
#   - ZSWAP_ENABLED: (true/false) - mutually exclusive with ZRAM
#   - ZRAM_ENABLED: (true/false)
#   - FIREWALL_SCRIPT: (none, simple-iptables, nftables-basic, etc.)
#   - BTRFS_SUBVOLS: (@,@home or custom list)
#   - BTRFS_COMPRESSION: (zstd,lzo,none)
#   - BTRFS_CHECKSUM: (xxhash,sha256,crc32c)
#
# DESIGN PHILOSOPHY NOTE: Even when these options are implemented, this script
# will remain opinionated. Not every combination will be supported. For example:
#   - Swap size always matches RAM up to 8GB maximum (unless custom override)
#   - ZSWAP and ZRAM are mutually exclusive; ZSWAP auto-enables with swap partitions
#   - Firewall selection limited to curated, well-tested scripts only
#   - Some paths simply won't be offered to avoid maintenance burden
#
# The goal is a coherent, maintainable system—not a generic framework.
# =============================================================================

validate_metadata() {
    local disk="$1"

    [[ "${CFG[VERSION]}" == "$VERSION" ]] ||
        die "Unsupported metadata version: ${CFG[VERSION]}"

    [[ "${CFG[DISK]}" == "$disk" ]] ||
        die "Metadata belongs to another disk: ${CFG[DISK]}"

    local expected_esp
    expected_esp=$(partition_path "$disk" 1)

    local expected_root
    expected_root=$(partition_path "$disk" 2)

    [[ "${CFG[ESP_PARTITION]}" == "$expected_esp" ]] ||
        die "ESP partition in metadata does not match disk."

    [[ "${CFG[ROOT_PARTITION]}" == "$expected_root" ]] ||
        die "Root partition in metadata does not match disk."

    valid_vfat_uuid "${CFG[ESP_UUID]}" ||
        die "Invalid ESP UUID."

    valid_uuid "${CFG[LUKS_UUID]}" ||
        die "Invalid LUKS UUID."

    valid_uuid "${CFG[BTRFS_UUID]}" ||
        die "Invalid Btrfs UUID."

    [[ "${CFG[LUKS_NAME]}" == "$LUKS_NAME" ]] ||
        die "Unexpected LUKS mapper name."

    [[ "${CFG[ROOT_SUBVOL]}" == "$BTRFS_ROOT_SUBVOL" ]] ||
        die "Unexpected root subvolume."

    [[ "${CFG[HOME_SUBVOL]}" == "$BTRFS_HOME_SUBVOL" ]] ||
        die "Unexpected home subvolume."

    [[ "${CFG[BTRFS_CHECKSUM]}" == "$BTRFS_CHECKSUM" ]] ||
        die "Unsupported Btrfs checksum: ${CFG[BTRFS_CHECKSUM]}"
}

find_metadata_on_esp() {
    local esp="$1"
    local existing_mount=''
    local path

    # If the ESP is already mounted anywhere (commonly /mnt/boot/efi after
    # Stage 1 or after the installer), read from that mount.  vfat does not
    # reliably support a second mount with different options.
    existing_mount=$(
        findmnt -rn -S "$esp" -o TARGET 2>/dev/null | head -n 1 || true
    )

    if [[ -n "$existing_mount" ]]; then
        path="${existing_mount}/${PREP_DIR}/prep-disk.conf"

        if [[ -f "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi

        return 1
    fi

    mkdir -p "$MOUNT_ESP"

    if is_mounted "$MOUNT_ESP"; then
        verify_esp_mount "$MOUNT_ESP" "$esp"
    else
        # On a fresh disk the ESP may not exist yet, and an unrelated
        # partition may occupy slot 1.  Detection must never abort Stage 1.
        [[ -b "$esp" ]] || return 1

        [[ "$(blkid -s TYPE -o value "$esp" 2>/dev/null || true)" == 'vfat' ]] ||
            return 1

        # Mount read-only: this path only looks for metadata and must not
        # modify a filesystem that may belong to another operating system.
        if ! mount -t vfat -o ro "$esp" "$MOUNT_ESP" 2>/dev/null; then
            warn "Could not mount $esp read-only; treating it as unprepared."
            return 1
        fi

        record_mount "$MOUNT_ESP"
    fi

    path=$(metadata_path "$MOUNT_ESP")

    [[ -f "$path" ]] || {
        if is_mounted "$MOUNT_ESP" && mount_is_owned "$MOUNT_ESP"; then
            run_cmd umount "$MOUNT_ESP"
            forget_mount "$MOUNT_ESP"
        fi

        return 1
    }

    printf '%s\n' "$path"
}

# ============================================================
# MANAGED CONFIGURATION BLOCKS
# ============================================================

replace_managed_block() {
    local path="$1"
    local begin="$2"
    local end="$3"
    local contents="$4"
    local mode="${5:-0644}"

    local old=''
    [[ -f "$path" ]] && old=$(cat -- "$path")

    local begins ends

    begins=$(
        awk -v marker="$begin" '$0 == marker { n++ } END { print n+0 }' \
            <<< "$old"
    )

    ends=$(
        awk -v marker="$end" '$0 == marker { n++ } END { print n+0 }' \
            <<< "$old"
    )

    (( begins <= 1 )) ||
        die "Multiple BEGIN markers in $path."

    (( ends <= 1 )) ||
        die "Multiple END markers in $path."

    if (( begins == 0 && ends == 0 )); then
        local new="$old"

        if [[ -n "$new" && "${new: -1}" != $'\n' ]]; then
            new+=$'\n'
        fi

        [[ -z "$new" || "${new: -2}" == $'\n\n' ]] ||
            new+=$'\n'

        new+="$begin"$'\n'
        new+="$contents"$'\n'
        new+="$end"$'\n'

        backup_file "$path"
        write_file "$path" "$new" "$mode"
        return 0
    fi

    (( begins == 1 && ends == 1 )) ||
        die "Incomplete managed block in $path."

    local new

    new=$(
        awk \
            -v begin="$begin" \
            -v end="$end" \
            -v replacement="$contents" '
            $0 == begin {
                print begin
                printf "%s\n", replacement
                inside=1
                next
            }

            $0 == end {
                inside=0
                print end
                next
            }

            !inside {
                print
            }

            END {
                if (inside)
                    exit 20
            }
            ' "$path"
    ) || die "Could not update managed block in $path."

    backup_file "$path"
    write_file "$path" "$new" "$mode"
}

strip_conflicting_fstab_entries() {
    local path="$1"
    local tmp
    local before
    local after

    [[ -f "$path" ]] || return 0

    tmp="${path}.prep_disk_new.$$"

    awk '
        $0 == "# BEGIN prep_disk.sh fstab" { inside=1; print; next }
        $0 == "# END prep_disk.sh fstab"   { inside=0; print; next }
        inside { print; next }
        /^[[:space:]]*#/ || NF < 2 { print; next }
        ($2 == "/" || $2 == "/home" || $2 == "/boot/efi") { next }
        { print }
    ' "$path" > "$tmp" || {
        rm -f -- "$tmp"
        die "Could not filter conflicting fstab entries in $path."
    }

    before=$(wc -l < "$path")
    after=$(wc -l < "$tmp")

    if cmp -s "$path" "$tmp"; then
        rm -f -- "$tmp"
        return 0
    fi

    backup_file "$path"
    chmod --reference="$path" "$tmp" 2>/dev/null || true
    chown --reference="$path" "$tmp" 2>/dev/null || true

    log "Removed conflicting installer fstab entries (${before} -> ${after} lines)."

    mv -f -- "$tmp" "$path"
}

strip_conflicting_crypttab_entries() {
    local path="$1"
    local name="$2"
    local uuid="$3"
    local rootpart="$4"
    local tmp
    local before
    local after

    [[ -f "$path" ]] || return 0

    tmp="${path}.prep_disk_new.$$"

    awk \
        -v name="$name" \
        -v uuid="UUID=$uuid" \
        -v rootpart="$rootpart" '
        $0 == "# BEGIN prep_disk.sh crypttab" { inside=1; print; next }
        $0 == "# END prep_disk.sh crypttab"   { inside=0; print; next }
        inside { print; next }
        /^[[:space:]]*#/ || NF < 1 { print; next }
        ($1 == name || tolower($2) == tolower(uuid) || $2 == rootpart) { next }
        { print }
    ' "$path" > "$tmp" || {
        rm -f -- "$tmp"
        die "Could not filter conflicting crypttab entries in $path."
    }

    before=$(wc -l < "$path")
    after=$(wc -l < "$tmp")

    if cmp -s "$path" "$tmp"; then
        rm -f -- "$tmp"
        return 0
    fi

    backup_file "$path"
    chmod --reference="$path" "$tmp" 2>/dev/null || true
    chown --reference="$path" "$tmp" 2>/dev/null || true

    log "Removed conflicting installer crypttab entries (${before} -> ${after} lines)."

    mv -f -- "$tmp" "$path"
}

# ============================================================
# PREPARATION METADATA WRITER
# ============================================================

write_preparation_metadata() {
    local disk="$1"
    local esp="$2"
    local root="$3"
    local esp_uuid="$4"
    local luks_uuid_value="$5"
    local btrfs_uuid_value="$6"

    local dir="${TARGET_ESP}/${PREP_DIR}"

    mkdir -p "$dir"

    # =====================================================================
    # FUTURE ENHANCEMENT TODO:
    #
    # fstab generation should be conditional based on storage stack:
    #
    # WHEN LVM ENABLED (preferred for Slackware compatibility):
    #   - Add VG/LV declarations in metadata
    #   - Write fstab entries referencing /dev/mapper/VG-LV paths
    #   - Include swap entry if swap LV created
    #   - Update LUKS_NAME to reflect VG (e.g., cryptvg)
    #
    # WHEN NO SWAP (zRAM relied upon):
    #   - Document zRAM dependency in README
    #   - Verify Slackware 16.0 alpha 1's setup enables zRAM
    #   - Optionally add swapfile creation post-mount
    #
    # WHEN SWAP PARTITION/LV CREATED:
    #   - Swap size matches installed RAM up to 8GB maximum
    #   - Mark whether swap is encrypted (within LUKS) or plaintext
    #   - Add ZSWAP kernel parameter to boot options (NOT with ZRAM)
    #   - ZSWAP is enabled with default kernel options by policy
    #
    # CURRENT WORKING FMTAB (from disk_setup.sh/finish_install.sh):
    #   - Uses UUID=$ROOT_UUID for Btrfs (not /dev/mapper path)
    #   - Separate subvol= options for @ and @home
    #   - Swap via device path (/dev/cryptvg/swap) when LVM exists
    # =====================================================================

    local fstab
    fstab=$(cat <<EOF
# Generated by $PROGRAM $VERSION.
# This file is imported into the managed fstab block.
#
# EFI System Partition
UUID=$esp_uuid    /boot/efi    vfat    defaults    0    0

# Btrfs root
UUID=$btrfs_uuid_value    /    btrfs    subvol=$BTRFS_ROOT_SUBVOL,compress=zstd    0    0

# Btrfs home
UUID=$btrfs_uuid_value    /home    btrfs    subvol=$BTRFS_HOME_SUBVOL,compress=zstd    0    0
EOF
)

    # =====================================================================
    # FUTURE ENHANCEMENT TODO:
    #
    # CRITICAL: crypttab's first field must match the mapper name that
    # Slackware's initrd actually creates.  Slackware's /init derives that
    # name as luks<basename(LUKS device)>, or uses the bare rootdev value
    # when the initrd's rootdev is a bare name.
    #
    # From repair-crypt-boot.sh:
    #   - Original: cryptlvm caused triple passphrase prompt
    #   - Fixed: renamed to luksmmcblk0p2 AND rebuilt initrd with -C /dev/mmcblk0p2
    #
    # Stage 2 therefore reads the installed initrd and writes crypttab using
    # the derived boot mapper name, not necessarily the Stage 1 name.
    #
    # RECOMMENDED FIX FOR FUTURE VERSIONS:
    #   - After Slackware installation, extract initrd and verify:
    #       zcat /boot/initrd.gz | cpio -idmu
    #       cat luksdev    # must match crypttab first field
    #       cat rootdev    # must match kernel root= parameter
    #   - If mismatch, rebuild initrd:
    #       mkinitrd -c -k <kernel> -r <root_dev> -C <luks_dev> -f <fs> -o /boot/initrd.gz
    #
    # WHEN ENCRYPTED SWAP IS ADDED:
    #   - Add separate LUKS container for swap (reuses same key or distinct)
    #   - Add crypttab entry for swap mapper
    #   - Enable ZSWAP (swaps compressed pages before hitting swap device)
    #   - Verify ZSWAP is DISABLED if ZRAM is active
    # =====================================================================

    local crypttab
    crypttab=$(cat <<EOF
# Generated by $PROGRAM $VERSION.
# INFORMATIONAL ONLY: this records the install-time mapper used by Stage 1.
# Stage 2 writes the final managed crypttab block using the mapper name
# that Slackware's installed initrd actually creates.

$LUKS_NAME    UUID=$luks_uuid_value    none    luks
EOF
)

    local conf
    conf=$(cat <<EOF
# $PROGRAM preparation metadata
# Generated by $PROGRAM $VERSION.

VERSION=$VERSION

DISK=$disk

ESP_PARTITION=$esp
ROOT_PARTITION=$root

ESP_UUID=$esp_uuid
LUKS_UUID=$luks_uuid_value
BTRFS_UUID=$btrfs_uuid_value

LUKS_NAME=$LUKS_NAME

ROOT_SUBVOL=$BTRFS_ROOT_SUBVOL
HOME_SUBVOL=$BTRFS_HOME_SUBVOL

BTRFS_CHECKSUM=$BTRFS_CHECKSUM
EOF
)

    # =====================================================================
    # FUTURE ENHANCEMENT TODO:
    #
    # README should be expanded with:
    #   - Chosen storage stack diagram
    #   - Whether LVM is used
    #   - Whether swap exists (partition, LV, or zRAM)
    #     - If swap partition/LV: note size (RAM-mapped, 8GB max)
    #     - Note whether swap is encrypted or plaintext
    #     - ZSWAP status (enabled with swap partitions, disabled with ZRAM)
    #   - Whether firewall script was enabled before snapshots
    #   - Exact initrd requirements
    #   - Known issues and workarounds from repair-crypt-boot.sh
    #   - Commands for verifying crypttab/initrd alignment
    #   - How to rebuild initrd if needed
    # =====================================================================

    local readme
    readme=$(cat <<EOF
Slackware prep_disk metadata
============================

Prepared by:
    $PROGRAM $VERSION

Project Evolution:
    This tool began as a simple automation script for setting up a
    BTRFS filesystem with modern options (compression, checksums,
    subvolumes) and full-disk encryption (LUKS2). It has since evolved
    into a more general-purpose pre and post-setup helper.

    While expanding capabilities, the script maintains opinionated
    design choices. Not every conceivable configuration will be
    supported—the goal is coherence and maintainability, not infinite
    flexibility.

Disk:
    $disk

Storage:
    GPT
    ESP: 1 GiB
    LUKS2: remaining disk
    Btrfs: inside LUKS2
    Btrfs checksum: $BTRFS_CHECKSUM

LUKS mapper:
    $LUKS_NAME

Btrfs subvolumes:
    $BTRFS_ROOT_SUBVOL -> /
    $BTRFS_HOME_SUBVOL -> /home

FUTURE CAPABILITIES (Not Yet Implemented):

    SWAP HANDLING:
        When swap partitions/LVs are created, they will be sized
        to match installed physical RAM, up to a maximum of 8 GB.
        This balances hibernation support with avoiding excessive
        disk allocation on systems with large RAM.

        ZSWAP POLICY: If swap partitions/LVs are used, ZSWAP will be
        enabled with default kernel options. ZSWAP compresses swapped
        pages before writing to the swap device.

        CRITICAL MUTUAL EXCLUSION: ZSWAP must NOT be enabled if the
        default ZRAM swap mechanism is active. ZRAM already provides
        compressed RAM-based swap; enabling ZSWAP on top would be
        redundant and potentially harmful.

    FIREWALL INTEGRATION:
        Before creating the first read-only Btrfs snapshots, users
        may optionally enable one of several simple, curated firewall
        scripts. This ensures the baseline snapshot represents a
        hardened system with network security configured.

BOOT METHOD
===========

This installation uses direct UEFI kernel booting.

The Linux kernel is loaded directly by UEFI firmware through its
EFI stub interface.  No traditional bootloader is installed or
configured by prep_disk.sh.

The finalization stage:

    1. verifies the installed Slackware kernel;
    2. verifies the installed initrd;
    3. copies both files to:

        /boot/efi/EFI/Slackware/

    4. creates or verifies a UEFI NVRAM Boot#### entry using efibootmgr;
    5. points that firmware entry directly at the kernel;
    6. passes the initrd path and Btrfs root parameters to the kernel.

The resulting boot path is:

    UEFI firmware
        -> Slackware kernel EFI stub
        -> initrd
        -> /dev/mapper/<mapper chosen by the initrd>
        -> Btrfs subvolume @
        -> /

WHY THIS IS DONE
================

A kernel copied to the ESP is not automatically a selectable firmware
boot-menu item on every system.  The firmware needs a Boot#### entry
describing which EFI executable to load.

The working boot method for this installation is direct kernel loading,
rather than a separate bootloader.  Therefore prep_disk.sh creates the
firmware entry itself.

This intentionally avoids:

    - LILO;
    - ELILO;
    - GRUB;
    - grub-install;
    - grub-mkconfig.

EFI NVRAM IS INTENTIONALLY MODIFIED
===================================

Because the desired boot-menu entry belongs to UEFI firmware, creating
it requires writing an EFI NVRAM Boot#### variable.

prep_disk.sh therefore uses:

    efibootmgr

during finalization.

This is an intentional change from older versions of this helper.
Earlier versions explicitly avoided EFI NVRAM and consequently did not
create a direct firmware kernel entry.

The helper manages only its own specifically named entry:

    $UEFI_BOOT_LABEL

It does not intentionally rewrite unrelated firmware boot entries.

INITRD RESPONSIBILITY AND VERIFICATION
======================================

CRITICAL: The Slackware installer's mkinitrd makes assumptions about
the storage stack. If the prepared storage differs from what mkinitrd
expects, boot will fail with multiple LUKS passphrase prompts or
device-not-found errors.

From repair-crypt-boot.sh (working fix):

    1. Extract and inspect the installed initrd:
        cd /tmp
        zcat /boot/initrd.gz | cpio -idmu
        cat luksdev    # Must match /etc/crypttab first field
        cat rootdev    # Must match kernel root= parameter
        cat rootfs     # Must match actual filesystem

    2. If mismatch detected, rebuild the initrd explicitly.  For this
       direct-LUKS layout the root device is the mapper the initrd will
       create (luks<partition>, for example lukssda2):
        mkinitrd \
          -c \
          -k <kernel_version> \
          -f btrfs \
          -r luks<partition> \
          -C /dev/<luks_partition> \
          -u \
          -o /boot/initrd.gz

       Add -L only if LVM is actually in use between LUKS and Btrfs.

    3. Verify new initrd matches before rebooting.

CURRENT BEHAVIOR: This helper inspects the installed initrd (rootdev,
luksdev, rootfs) before finalizing.  If no initrd exists, or if the
existing one cannot reach the prepared root, it generates a replacement
with mkinitrd using explicit flags.  It does not rely on the installer's
optional MKINITRD step or on geninitrd's automatic detection.

INITRD GENERATION
=================

The generic kernel package does not ship an initrd.  The installer's
MKINITRD step is optional and easy to miss, and geninitrd falls back to
mkinitrd_command_generator.sh when /etc/mkinitrd.conf is absent.  That
generator does not reliably detect a root that was already unlocked by
the installer.

When Stage 2 finds no initrd, or finds one that cannot reach the prepared
root, it runs this inside the installed system:

    mkinitrd -c -k <kernel-version> -f btrfs -r luks<partition> \
        -C UUID=<luks-uuid> -u -o /boot/initrd-<kernel-version>.img

It bind-mounts /proc, /sys and /dev into the target for the duration of
the command, creates the same initrd.gz/initrd-<name>.img symlinks that
geninitrd uses, and verifies rootdev, luksdev and rootfs afterwards.

The direct kernel entry passes:

    rootflags=subvol=$BTRFS_ROOT_SUBVOL
    rw
    initrd=\\EFI\\Slackware\\<initrd>

and a root= value derived from the initrd itself:

    - if the initrd's rootdev is an absolute path, that path is used;
    - if the initrd's rootdev is a bare mapper name (for example
      "cryptroot"), root= is omitted and the initrd's own rootdev is used.

The initrd must therefore contain the necessary support for unlocking
the LUKS2 root and mounting the Btrfs root filesystem.

SWAP NOTICE
===========

Current implementation does not create a swap partition or logical volume.

Slackware 16.0 alpha 1's setup utility configures zRAM when no swap is
detected. This provides swap functionality but has different characteristics
than a dedicated swap partition/LV.

OPINIONATED SWAP POLICY (FUTURE):
    When swap is eventually added, the script will enforce these rules:
    - Size matches installed RAM, capped at 8 GB maximum
    - ZSWAP enabled for swap partitions/LVs (not for ZRAM)
    - Clear documentation of encryption status (encrypted vs plaintext)

FIREWALL INTEGRATION (FUTURE):
    Before the first Btrfs read-only snapshots are created, users may
    optionally enable one of several curated firewall scripts. This
    ensures the snapshot baseline includes network security hardening.

    This happens BEFORE snapshots because:
    - Snapshots represent a known-good system state
    - Having firewall configured ensures security from first boot
    - Changes after snapshotting don't affect the baseline

FINALIZATION
============

After installation, invoke:

    $PROGRAM $disk

This helper:

    - verifies the prepared storage;
    - updates its own fstab/crypttab blocks;
    - removes conflicting installer entries for those mountpoints;
    - verifies/copies the installed kernel and initrd to the ESP;
    - generates the installed initrd with mkinitrd when missing or
      unsuitable for the prepared LUKS/Btrfs layout;
    - verifies direct EFI-stub kernel suitability;
    - creates/verifies the direct UEFI firmware boot entry;
    - verifies the kernel, initrd and UEFI entry before succeeding;
    - creates initial read-only Btrfs snapshots.

This helper does NOT:

    - install LILO;
    - install ELILO;
    - install GRUB;
    - configure LILO;
    - configure ELILO;
    - configure GRUB.

IMPORTANT BOOT TROUBLESHOOTING
==============================

If boot prompts for LUKS passphrase multiple times:

    1. Check /etc/crypttab LUKS name
    2. Boot rescue shell and extract initrd:
        cd /tmp
        zcat /boot/initrd.gz | cpio -idmu
        cat luksdev    # Compare with crypttab
        cat rootdev    # Compare with kernel root=
    3. If mismatch, rebuild initrd as shown above
    4. If still failing, check LVM metadata (if applicable):
        grep 'device =' /etc/lvm/backup/<VG_NAME>

See repair-crypt-boot.sh for working example.
EOF
)

    write_file "${dir}/prep-fstab" "$fstab" 0644
    write_file "${dir}/prep-crypttab" "$crypttab" 0600
    write_file "${dir}/prep-disk.conf" "$conf" 0644
    write_file "${dir}/README.txt" "$readme" 0644
}

# ============================================================
# STAGE 1
# ============================================================

prepare_disk() {
    local disk="$1"
    local esp
    local root

    esp=$(partition_path "$disk" 1)
    root=$(partition_path "$disk" 2)

    verify_disk_unmounted "$disk"

    log
    log "============================================================"
    log " Slackware disk preparation"
    log "============================================================"
    log
    log "Program : $PROGRAM $VERSION"
    log "Disk    : $disk"
    log
    log "DESTRUCTIVE OPERATION"
    log
    log "The entire disk will be erased."
    log
    log "Layout:"
    log "    GPT"
    log "    p1  1 GiB EFI System Partition"
    log "    p2  remaining disk, LUKS2"
    log "    Btrfs inside LUKS2"
    log "    subvolumes: $BTRFS_ROOT_SUBVOL, $BTRFS_HOME_SUBVOL"
    log "    checksum: $BTRFS_CHECKSUM"
    log
    log "Boot design:"
    log "    direct UEFI -> EFI-stub Linux kernel"
    log "    no LILO / ELILO / GRUB"
    log
    log "================================================================"
    log " FUTURE ENHANCEMENT PROMPT: Current version hardcodes single layout."
    log " Future versions should present interactive options for:"
    log "   - ESP size (256MiB-1GiB)"
    log "   - Encryption (LUKS2, LUKS1, none)"
    log "   - LVM (enabled/disabled, VG name)"
    log "   - Filesystem (Btrfs, ext4, XFS)"
    log "   - Swap (LV, partition, file, zRAM)"
    log "     - Policy: size = RAM, max 8GB"
    log "     - Policy: ZSWAP enabled with swap partitions (not with ZRAM)"
    log "   - Firewall (enable before snapshots, curated scripts only)"
    log "   - Btrfs subvolume layout (custom or @/@home)"
    log "================================================================"
    log
    log "NOTE ON DESIGN PHILOSOPHY:"
    log "    Even when enhanced, this script will remain opinionated."
    log "    Not every configuration will ever be supported."
    log "    The goal is coherence, not infinite flexibility."
    log
    confirm_yes "ERASE AND REPARTITION $disk?" ||
        die "Aborted."

    log
    log "Current device layout:"
    log

    lsblk \
        -o NAME,SIZE,TYPE,FSTYPE,PARTTYPE,UUID,MOUNTPOINT \
        "$disk" ||
        die "Could not inspect $disk."

    log

    confirm_yes "The device above is CORRECT?" ||
        die "Aborted."

    log
    log "FINAL WARNING"
    log "============="
    log "ALL DATA ON $disk WILL BE DESTROYED."
    log

    confirm_yes "Proceed with irreversible disk preparation?" ||
        die "Aborted."

    # --------------------------------------------------------
    # Partition table
    # --------------------------------------------------------

    if command_exists wipefs; then
        run_cmd wipefs -a "$disk"
    else
        warn "wipefs is not available; relying on sgdisk --zap-all."
    fi

    run_cmd sgdisk \
        --zap-all \
        "$disk"

    run_cmd sgdisk \
        --new=1:1M:+$ESP_SIZE \
        --typecode=1:EF00 \
        --change-name=1:EFI \
        --new=2:0:0 \
        --typecode=2:"$ROOT_TYPE_GUID" \
        --change-name=2:cryptroot \
        "$disk"

    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    [[ -b "$esp" ]] ||
        die "ESP partition did not appear: $esp"

    [[ -b "$root" ]] ||
        die "Root partition did not appear: $root"

    verify_partition_layout "$disk" "$esp" "$root"

    # --------------------------------------------------------
    # ESP
    # --------------------------------------------------------

    run_cmd mkfs.fat \
        -F 32 \
        -n EFI \
        "$esp"

    local esp_uuid
    esp_uuid=$(partition_uuid "$esp")

    valid_vfat_uuid "$esp_uuid" ||
        die "Could not obtain valid ESP UUID."

    # --------------------------------------------------------
    # LUKS
    # --------------------------------------------------------

    log
    log "LUKS2 password"
    log

    local password
    password=$(prompt_password 'Enter LUKS2 password: ')

    [[ -n "$password" ]] ||
        die "Password may not be empty."

    local confirmation
    confirmation=$(prompt_password 'Confirm LUKS2 password: ')

    [[ "$password" == "$confirmation" ]] ||
        die "Passwords do not match."

    unset confirmation

    # Do NOT append a newline: cryptsetup --key-file - treats the whole
    # stream as the key, so a newline would become part of the passphrase.
    printf '%s' "$password" |
        cryptsetup luksFormat \
            --type luks2 \
            --batch-mode \
            --key-file - \
            "$root" ||
        die "cryptsetup luksFormat failed."

    require_luks2 "$root"

    local luks_uuid_value
    luks_uuid_value=$(luks_uuid "$root")

    valid_uuid "$luks_uuid_value" ||
        die "Could not obtain valid LUKS UUID."

    # --------------------------------------------------------
    # Open LUKS
    # --------------------------------------------------------

    open_luks_with_password \
        "$root" \
        "$LUKS_NAME" \
        "$password"

    unset password

    local mapper="/dev/mapper/$LUKS_NAME"

    verify_mapper \
        "$root" \
        "$LUKS_NAME" \
        "$luks_uuid_value"

    # =====================================================================
    # FUTURE ENHANCEMENT TODO:
    #
    # LVM CREATION (OPTIONAL - recommended for Slackware compatibility):
    #
    # To add LVM support, insert here AFTER LUKS open:
    #
    #     local vg_name="${LUKS_NAME}vg"    # Or configurable name
    #
    #     run_cmd pvcreate "$mapper"
    #     run_cmd vgcreate "$vg_name" "$mapper"
    #
    #     # Root LV (remaining space)
    #     run_cmd lvcreate -l 100%FREE -n root "$vg_name"
    #
    #     # Optional swap LV
    #     if (( CREATE_SWAP )); then
    #         run_cmd lvcreate -L "$SWAP_SIZE" -n swap "$vg_name"
    #     fi
    #
    # Update subsequent references:
    #   - mapper variable becomes /dev/mapper/$vg_name-root
    #   - LUKS_NAME in metadata stays as LUKS mapper (not VG)
    #   - fstab writes /dev/mapper/VG-root instead of direct mapper
    #   - Kernel cmdline root=/dev/mapper/VG-root
    #
    # IMPORTANT: This aligns with disk_setup.sh/finish_install.sh proven
    # configuration that required repair-crypt-boot.sh fix.
    # =====================================================================

    # --------------------------------------------------------
    # Btrfs
    # --------------------------------------------------------

    log
    log "Creating Btrfs filesystem..."
    log "Checksum: $BTRFS_CHECKSUM"
    log

    run_cmd mkfs.btrfs \
        -f \
        --checksum "$BTRFS_CHECKSUM" \
        "$mapper"

    local btrfs_uuid_value
    btrfs_uuid_value=$(btrfs_uuid "$mapper")

    valid_uuid "$btrfs_uuid_value" ||
        die "Could not obtain valid Btrfs UUID."

    verify_btrfs \
        "$mapper" \
        "$btrfs_uuid_value"

    # --------------------------------------------------------
    # Subvolumes
    # --------------------------------------------------------

    mkdir -p "$MOUNT_ROOT"

    run_cmd mount "$mapper" "$MOUNT_ROOT"
    record_mount "$MOUNT_ROOT"

    run_cmd btrfs subvolume create \
        "${MOUNT_ROOT}/${BTRFS_ROOT_SUBVOL}"

    run_cmd btrfs subvolume create \
        "${MOUNT_ROOT}/${BTRFS_HOME_SUBVOL}"

    run_cmd sync

    run_cmd umount "$MOUNT_ROOT"
    forget_mount "$MOUNT_ROOT"

    mount_btrfs_top "$mapper"

    verify_subvolume "$MOUNT_TOP" "$BTRFS_ROOT_SUBVOL"
    verify_subvolume "$MOUNT_TOP" "$BTRFS_HOME_SUBVOL"

    # Slackware's initrd and the installer both mount the root device without
    # an explicit subvol= argument in some code paths.  Making @ the default
    # subvolume ensures those paths still land on @ rather than on the
    # top-level subvolume (which contains only @ and @home).
    ensure_default_subvolume "$MOUNT_TOP" "$BTRFS_ROOT_SUBVOL"

    run_cmd umount "$MOUNT_TOP"
    forget_mount "$MOUNT_TOP"

    # --------------------------------------------------------
    # Target mounts
    # --------------------------------------------------------

    mount_prepared_target \
        "$mapper" \
        "$BTRFS_ROOT_SUBVOL" \
        "$BTRFS_HOME_SUBVOL" \
        "$esp"

    verify_prepared_target \
        "$mapper" \
        "$BTRFS_ROOT_SUBVOL" \
        "$BTRFS_HOME_SUBVOL" \
        "$esp"

    # --------------------------------------------------------
    # Metadata
    # --------------------------------------------------------

    write_preparation_metadata \
        "$disk" \
        "$esp" \
        "$root" \
        "$esp_uuid" \
        "$luks_uuid_value" \
        "$btrfs_uuid_value"

    run_cmd sync

    log
    log "============================================================"
    log " Disk preparation complete"
    log "============================================================"
    log
    log "Disk       : $disk"
    log "ESP        : $esp"
    log "ESP UUID   : $esp_uuid"
    log "LUKS       : $root"
    log "LUKS UUID  : $luks_uuid_value"
    log "Mapper     : $mapper"
    log "Btrfs UUID : $btrfs_uuid_value"
    log "Checksum   : $BTRFS_CHECKSUM"
    log
    log "Root       : $BTRFS_ROOT_SUBVOL -> /mnt"
    log "Home       : $BTRFS_HOME_SUBVOL -> /mnt/home"
    log
    log "Boot       : direct UEFI EFI-stub kernel"
    log "Boot entry : created during finalization"
    log
    log "================================================================"
    log " IMPORTANT: during setup, do NOT format the ESP ($esp)."
    log " The prep_disk metadata is stored there."
    log
    log " After package installation, install the generic kernel.  Running"
    log " the installer's MKINITRD step is optional: finalization generates"
    log " an initrd if it is missing and verifies LUKS/Btrfs support before"
    log " creating the boot entry."
    log "================================================================"
    log
    log "The normal Slackware installer can now be run."
    log
    log "After installation:"
    log
    log "    $PROGRAM $disk"
    log

    SUCCESS=1
}

# ============================================================
# STAGE 2 — STORAGE VERIFICATION
# ============================================================

verify_prepared_disk() {
    local disk="$1"

    verify_partition_layout \
        "$disk" \
        "${CFG[ESP_PARTITION]}" \
        "${CFG[ROOT_PARTITION]}"

    local actual_esp_uuid
    actual_esp_uuid=$(partition_uuid "${CFG[ESP_PARTITION]}")

    [[ "${actual_esp_uuid,,}" == "${CFG[ESP_UUID],,}" ]] ||
        die "ESP UUID mismatch."

    require_luks2 "${CFG[ROOT_PARTITION]}"

    local actual_luks_uuid
    actual_luks_uuid=$(luks_uuid "${CFG[ROOT_PARTITION]}")

    [[ "${actual_luks_uuid,,}" == "${CFG[LUKS_UUID],,}" ]] ||
        die "LUKS UUID mismatch."

    log "Storage verification: PASS"
}

# ============================================================
# TARGET ROOT
# ============================================================

determine_target_root() {
    # Installer environment (or an installed system whose @ is mounted at
    # /mnt by mount_prepared_target).
    if [[ -f "${TARGET_ROOT}/etc/slackware-version" &&
          -f "${TARGET_ROOT}/etc/fstab" ]]; then
        printf '%s\n' "$TARGET_ROOT"
        return 0
    fi

    # Running from the installed system itself: /mnt is an alias for the
    # same filesystem as /.  Do NOT fall back to / merely because the live
    # installer has /etc/slackware-version; that would modify the live
    # environment when the target installation is incomplete.
    if [[ -f /etc/slackware-version ]] &&
       same_device "$(mount_source /)" "$(mount_source "$TARGET_ROOT")"; then
        printf '/\n'
        return 0
    fi

    die "Cannot identify a complete installed Slackware root at ${TARGET_ROOT} (expected ${TARGET_ROOT}/etc/slackware-version and ${TARGET_ROOT}/etc/fstab)."
}

# ============================================================
# KERNEL / INITRD
# ============================================================

resolve_installed_file() {
    local root="$1"
    shift

    local candidate resolved

    for candidate in "$@"; do
        if [[ -f "$candidate" ]]; then
            resolved=$(readlink -f "$candidate" 2>/dev/null || true)

            if [[ -f "$resolved" ]]; then
                printf '%s\n' "$resolved"
            else
                printf '%s\n' "$candidate"
            fi

            return 0
        fi
    done

    return 1
}

resolve_kernel() {
    local root="$1"

    resolve_installed_file \
        "$root" \
        "${root}/boot/vmlinuz-generic" \
        "${root}/boot/vmlinuz-huge" \
        "${root}/boot/vmlinuz"
}

resolve_initrd() {
    local root="$1"

    resolve_installed_file \
        "$root" \
        "${root}/boot/initrd.gz" \
        "${root}/boot/initrd"
}

initrd_cat_file() {
    local initrd="$1"
    local member="$2"
    local result=''
    local offset
    local magic

    # Detect the compression from the file contents.  mkinitrd names its
    # output /boot/initrd-<version>.img even when it is gzip-compressed,
    # so the extension is not a reliable indicator.
    magic=$(od -An -tx1 -N6 -- "$initrd" 2>/dev/null | tr -d '[:space:]')

    case "$magic" in
        fd377a585a00*)
            result=$(xzcat -- "$initrd" 2>/dev/null |
                cpio -i --to-stdout -- "$member" 2>/dev/null || true)
            ;;
        1f8b*)
            result=$(zcat -- "$initrd" 2>/dev/null |
                cpio -i --to-stdout -- "$member" 2>/dev/null || true)
            ;;
        425a68*)
            result=$(bzcat -- "$initrd" 2>/dev/null |
                cpio -i --to-stdout -- "$member" 2>/dev/null || true)
            ;;
        *)
            result=$(cpio -i --to-stdout -- "$member" < "$initrd" 2>/dev/null || true)
            ;;
    esac

    # Slackware's mkinitrd -P prepends an uncompressed microcode cpio
    # archive.  zcat then fails on the leading bytes.  Locate the gzip
    # header(s) and try decompressing from each one in turn.  This also
    # covers a .img file that is gzip-compressed behind a cpio prefix.
    if [[ -z "$result" ]]; then
        while IFS=: read -r offset _; do
            [[ -n "$offset" ]] || continue

            result=$(tail -c +$(( offset + 1 )) -- "$initrd" 2>/dev/null |
                zcat 2>/dev/null |
                cpio -i --to-stdout -- "$member" 2>/dev/null || true)

            [[ -n "$result" ]] && break
        done < <(
            LC_ALL=C grep -abo -- $'\x1f\x8b\x08' "$initrd" 2>/dev/null |
                head -n 16
        )
    fi

    printf '%s\n' "$result"
}

device_spec_matches_partition() {
    local spec="$1"
    local partition="$2"

    case "$spec" in
        UUID=*)
            [[ "$(partition_uuid "$partition")" == "${spec#UUID=}" ]]
            ;;
        LABEL=*)
            [[ "$(blkid -s LABEL -o value "$partition" 2>/dev/null || true)" == "${spec#LABEL=}" ]]
            ;;
        PARTUUID=*)
            [[ "$(blkid -s PARTUUID -o value "$partition" 2>/dev/null || true)" == "${spec#PARTUUID=}" ]]
            ;;
        /dev/*)
            same_device "$spec" "$partition"
            ;;
        *)
            [[ "$(basename "$spec")" == "$(basename "$partition")" ]]
            ;;
    esac
}

initrd_luks_spec_to_device() {
    local spec="$1"

    case "$spec" in
        UUID=*|LABEL=*|PARTUUID=*)
            findfs "$spec" 2>/dev/null || printf '%s\n' "$spec"
            ;;
        *)
            printf '%s\n' "$spec"
            ;;
    esac
}

# ------------------------------------------------------------
# INITRD GENERATION
# ------------------------------------------------------------

kernel_version_from_file() {
    local kernel="$1"
    local base
    local version=''

    [[ -f "$kernel" ]] || return 1

    base=$(basename -- "$kernel")

    case "$base" in
        vmlinuz-generic-*) version="${base#vmlinuz-generic-}" ;;
        vmlinuz-huge-*)    version="${base#vmlinuz-huge-}" ;;
        vmlinuz-*)         version="${base#vmlinuz-}" ;;
    esac

    if [[ -z "$version" ]] && command_exists strings; then
        version=$(strings -- "$kernel" 2>/dev/null |
            grep -E '\([^ ]*@[^ ]*\) #' 2>/dev/null |
            head -n 1 |
            cut -d' ' -f1)
    fi

    printf '%s\n' "$version"
}

# Non-fatal sanity check used before deciding whether an existing initrd
# can boot the prepared layout.  Detailed verification (mapper naming,
# EFI stub, etc.) still happens in inspect_installed_boot().
initrd_quick_check() {
    local initrd="$1"
    local rootdev luksdev rootfs spec found=0
    local old_ifs="$IFS"

    [[ -f "$initrd" ]] || return 1

    rootdev=$(initrd_cat_file "$initrd" rootdev | tr -d '\r' | head -n 1)
    luksdev=$(initrd_cat_file "$initrd" luksdev | tr -d '\r' | head -n 1)
    rootfs=$(initrd_cat_file "$initrd" rootfs | tr -d '\r' | head -n 1)

    [[ -n "$rootdev" && -n "$luksdev" && -n "$rootfs" ]] || return 1

    [[ "$rootfs" == 'btrfs' ]] || return 1

    # Slackware's init script does not resolve PARTUUID= for root=.
    [[ "$rootdev" != PARTUUID=* ]] || return 1

    IFS=':'
    for spec in $luksdev; do
        if device_spec_matches_partition "$spec" "${CFG[ROOT_PARTITION]}"; then
            found=1
            break
        fi
    done
    IFS="$old_ifs"

    (( found )) || return 1

    # If rootdev names /dev/mapper/X, Slackware's init will create
    # /dev/mapper/luks<basename(luks device)>.  They must agree.
    if [[ "$rootdev" == /dev/mapper/* ]]; then
        local mapper_device
        mapper_device=$(initrd_luks_spec_to_device "$spec")

        if [[ "$mapper_device" == /dev/* ]]; then
            [[ "${rootdev#/dev/mapper/}" == "luks$(basename -- "$mapper_device")" ]] ||
                return 1
        fi
    fi

    return 0
}

generate_installed_initrd() {
    local target_root="$1"
    local kernel kver mapper_name output output_host
    local rc=0
    local item

    kernel=$(resolve_kernel "$target_root") ||
        die "No Slackware kernel found under ${target_root}/boot."

    kver=$(kernel_version_from_file "$kernel")

    [[ -n "$kver" ]] ||
        die "Could not determine the kernel version from $kernel."

    [[ -d "${target_root}/lib/modules/${kver}" ]] ||
        die "Kernel modules for $kver are not installed under ${target_root}/lib/modules. Install the matching kernel-modules package."

    [[ -x "${target_root}/sbin/mkinitrd" ]] ||
        die "mkinitrd is not installed in the target. Install the mkinitrd package, then re-run finalization."

    mapper_name="luks$(basename -- "${CFG[ROOT_PARTITION]}")"
    [[ "$mapper_name" =~ ^[A-Za-z0-9_.-]+$ ]] || mapper_name='luksroot'

    output="/boot/initrd-${kver}.img"
    output_host="${target_root}${output}"

    log
    log "============================================================"
    log " Generating the installed initrd"
    log "============================================================"
    log
    log "Kernel      : $kernel"
    log "Version     : $kver"
    log "Root mapper : $mapper_name"
    log "LUKS device : UUID=${CFG[LUKS_UUID]}"
    log "Output      : $output"
    log

    if [[ -f "$output_host" ]]; then
        backup_file "$output_host"
    fi

    for item in initrd.gz initrd-generic.img initrd-huge.img; do
        if [[ -f "${target_root}/boot/${item}" || -L "${target_root}/boot/${item}" ]]; then
            backup_file "${target_root}/boot/${item}"
        fi
    done

    # mkinitrd may inspect /proc, /sys and /dev.  Bind the live copies
    # into the target while it runs.  record_mount() lets the global
    # cleanup trap remove them if we are interrupted.
    if [[ "$target_root" != '/' ]]; then
        for item in proc sys dev; do
            if ! is_mounted "${target_root}/${item}"; then
                mkdir -p "${target_root}/${item}"
                mount --bind "/${item}" "${target_root}/${item}" ||
                    die "Could not bind-mount /${item} into ${target_root}."
                record_mount "${target_root}/${item}"
            fi
        done
    fi

    log "Running mkinitrd in the target..."

    # -m is required: "-f btrfs" only records rootfs; mkinitrd does not
    # add the filesystem or storage modules by itself.  The extra list
    # covers the common virtio/SATA/NVMe/USB/MMC stacks.
    local initrd_modules='btrfs:dm-crypt:dm-mod:sd_mod:ahci:virtio_blk:virtio_pci:virtio_scsi:nvme:nvme_core:usb-storage:uas:xhci_pci:ehci_pci:ohci_pci:mmc_block:sdhci:sdhci_pci'

    chroot "$target_root" /sbin/mkinitrd \
        -c \
        -k "$kver" \
        -f btrfs \
        -r "$mapper_name" \
        -C "UUID=${CFG[LUKS_UUID]}" \
        -m "$initrd_modules" \
        -u \
        -o "$output" || rc=$?

    if (( rc != 0 )); then
        warn "mkinitrd rejected -C UUID=...; retrying with ${CFG[ROOT_PARTITION]}."
        rc=0

        chroot "$target_root" /sbin/mkinitrd \
            -c \
            -k "$kver" \
            -f btrfs \
            -r "$mapper_name" \
            -C "${CFG[ROOT_PARTITION]}" \
            -m "$initrd_modules" \
            -u \
            -o "$output" || rc=$?
    fi

    if [[ "$target_root" != '/' ]]; then
        for item in dev sys proc; do
            if mount_is_owned "${target_root}/${item}"; then
                umount "${target_root}/${item}" || true
                forget_mount "${target_root}/${item}"
            fi
        done
    fi

    (( rc == 0 )) ||
        die "mkinitrd failed to generate $output (exit $rc)."

    [[ -s "$output_host" ]] ||
        die "mkinitrd reported success but $output_host is missing or empty."

    # Match the naming geninitrd uses, so other Slackware tools find it.
    ln -sfn "$(basename -- "$output")" "${target_root}/boot/initrd.gz"

    case "$(basename -- "$kernel")" in
        vmlinuz-generic-*)
            ln -sfn "$(basename -- "$output")" "${target_root}/boot/initrd-generic.img"
            ;;
        vmlinuz-huge-*)
            ln -sfn "$(basename -- "$output")" "${target_root}/boot/initrd-huge.img"
            ;;
    esac

    run_cmd sync

    log "Generated initrd:"
    log "    $output_host"
}

ensure_installed_initrd() {
    local target_root="$1"
    local initrd=''

    if initrd=$(resolve_initrd "$target_root"); then
        if initrd_quick_check "$initrd"; then
            log "Installed initrd verified: $initrd"
            return 0
        fi

        warn "The installed initrd does not contain the LUKS/Btrfs layout for this target; regenerating it."
    else
        log "No installed initrd was found; generating one with mkinitrd."
    fi

    generate_installed_initrd "$target_root"

    initrd=$(resolve_initrd "$target_root") ||
        die "initrd generation did not create ${target_root}/boot/initrd.gz."

    initrd_quick_check "$initrd" ||
        die "The generated initrd still does not match the prepared LUKS/Btrfs layout: $initrd"

    log "Generated initrd verified: $initrd"
}

inspect_installed_boot() {
    local target_root="$1"

    KERNEL_SOURCE=$(resolve_kernel "$target_root") ||
        die "No Slackware kernel found under ${target_root}/boot."

    # The generic kernel package does not ship an initrd, and the
    # installer's optional MKINITRD step is easy to miss.  Generate one
    # here when it is absent or does not match the prepared storage.
    ensure_installed_initrd "$target_root"

    INITRD_SOURCE=$(resolve_initrd "$target_root") ||
        die "No installed initrd was found after generation at ${target_root}/boot."

    INITRD_ROOTDEV=$(initrd_cat_file "$INITRD_SOURCE" rootdev | tr -d '\r' | head -n 1)
    INITRD_LUKSDEV=$(initrd_cat_file "$INITRD_SOURCE" luksdev | tr -d '\r' | head -n 1)
    INITRD_ROOTFS=$(initrd_cat_file "$INITRD_SOURCE" rootfs | tr -d '\r' | head -n 1)

    log
    log "Installed initrd configuration:"
    log "    rootdev : ${INITRD_ROOTDEV:-<missing>}"
    log "    luksdev : ${INITRD_LUKSDEV:-<missing>}"
    log "    rootfs  : ${INITRD_ROOTFS:-<missing>}"
    log

    [[ -n "$INITRD_ROOTDEV" ]] ||
        die "The installed initrd has no rootdev file. Rebuild it with Slackware's mkinitrd."

    [[ -n "$INITRD_ROOTFS" ]] ||
        die "The installed initrd has no rootfs file. Rebuild it with Slackware's mkinitrd."

    [[ "$INITRD_ROOTFS" == 'btrfs' ]] ||
        die "The installed initrd expects rootfs '$INITRD_ROOTFS', not btrfs."

    local luks_spec=''
    local luks_device=''
    local candidate

    local old_ifs="$IFS"
    IFS=':'
    for candidate in $INITRD_LUKSDEV; do
        if device_spec_matches_partition "$candidate" "${CFG[ROOT_PARTITION]}"; then
            luks_spec="$candidate"
            luks_device=$(initrd_luks_spec_to_device "$candidate")
            break
        fi
    done
    IFS="$old_ifs"

    [[ -n "$luks_spec" ]] ||
        die "The installed initrd does not list ${CFG[ROOT_PARTITION]} in luksdev. Rebuild it with mkinitrd -C ${CFG[ROOT_PARTITION]}."

    local derived_mapper
    derived_mapper="luks$(basename "$luks_device")"

    case "$INITRD_ROOTDEV" in
        /dev/*)
            BOOT_LUKS_NAME="$derived_mapper"
            ;;
        UUID=*|LABEL=*)
            BOOT_LUKS_NAME="$derived_mapper"
            ;;
        PARTUUID=*)
            die "The installed initrd uses root=PARTUUID, which Slackware's init script does not resolve. Rebuild it with mkinitrd -r $derived_mapper -C ${CFG[ROOT_PARTITION]} -u -o /boot/initrd.gz"
            ;;
        */*)
            die "Unsupported initrd rootdev value: $INITRD_ROOTDEV"
            ;;
        *)
            # Slackware's init script treats a bare rootdev as the requested
            # LUKS mapper name and opens the encrypted device under that name.
            BOOT_LUKS_NAME="$INITRD_ROOTDEV"
            ;;
    esac

    [[ "$BOOT_LUKS_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] ||
        die "Refusing to use an unsafe boot LUKS mapper name: $BOOT_LUKS_NAME"

    if [[ "$INITRD_ROOTDEV" == /dev/mapper/* ]]; then
        if [[ "$INITRD_ROOTDEV" == "/dev/mapper/$BOOT_LUKS_NAME" ]]; then
            :
        else
            local lv_base="${INITRD_ROOTDEV#/dev/mapper/}"
            local lv_vg="${lv_base%%-*}"
            local lv_lv="${lv_base#*-}"

            if command_exists lvs &&
               lvs --noheadings -o vg_name,lv_name 2>/dev/null |
                   awk -v vg="$lv_vg" -v lv="$lv_lv" \
                       '$1 == vg && $2 == lv { found=1 } END { exit !found }'; then
                :
            else
                die "The installed initrd expects root=$INITRD_ROOTDEV, but Slackware's initrd will create /dev/mapper/$BOOT_LUKS_NAME. This initrd cannot boot this direct-LUKS layout. Rebuild it with: mkinitrd -c -k <kernel-version> -f btrfs -r $BOOT_LUKS_NAME -C ${CFG[ROOT_PARTITION]} -u -o /boot/initrd.gz"
            fi
        fi
    fi

    log "Initrd-derived boot mapper: $BOOT_LUKS_NAME"
    log

    log "Installed kernel:"
    log "    $KERNEL_SOURCE"

    log "Installed initrd:"
    log "    $INITRD_SOURCE"

    # Fail before modifying fstab/crypttab if the kernel cannot be booted
    # directly by UEFI firmware.
    verify_efi_stub_kernel "$KERNEL_SOURCE"
}

ensure_file_on_esp() {
    local source="$1"
    local destination="$2"
    local description="$3"

    [[ -f "$source" ]] ||
        die "$description source does not exist: $source"

    mkdir -p "$(dirname "$destination")"

    if [[ -f "$destination" ]] &&
       cmp -s "$source" "$destination"; then
        log "$description already matches ESP copy:"
        log "    $destination"
        return 0
    fi

    if [[ -f "$destination" ]]; then
        backup_file "$destination"
    fi

    log "Installing $description onto ESP:"
    log "    $source"
    log " -> $destination"

    run_cmd cp -f -- "$source" "$destination"
}

# ------------------------------------------------------------
# EFI STUB VERIFICATION
# ------------------------------------------------------------

is_efi_stub_kernel() {
    local kernel="$1"

    [[ -f "$kernel" ]] || return 1

    # Linux EFI-stub kernels are PE/COFF images with the PE signature
    # beginning at the offset stored in the DOS header at 0x3c.
    #
    # This is intentionally a lightweight structural check.  It verifies
    # the PE/COFF signature rather than depending on a particular objdump
    # implementation or architecture-specific output.
    local pe_offset
    local signature

    command_exists od || return 1

    pe_offset=$(
        od \
            -An \
            -j 60 \
            -N 4 \
            -t u4 \
            "$kernel" 2>/dev/null |
            tr -d '[:space:]'
    ) || return 1

    [[ "$pe_offset" =~ ^[0-9]+$ ]] || return 1

    signature=$(
        od \
            -An \
            -j "$pe_offset" \
            -N 4 \
            -t x1 \
            "$kernel" 2>/dev/null |
            tr -d '[:space:]' |
            tr '[:lower:]' '[:upper:]'
    ) || return 1

    [[ "$signature" == '50450000' ]]
}

verify_efi_stub_kernel() {
    local kernel="$1"

    is_efi_stub_kernel "$kernel" ||
        die "Kernel does not appear to be a PE/COFF EFI-stub image: $kernel"

    log "EFI-stub kernel verification: PASS"
}

# ============================================================
# DIRECT UEFI BOOT ENTRY
# ============================================================

require_uefi_runtime() {
    command_exists efibootmgr ||
        die "efibootmgr is required to create the direct UEFI boot entry."

    [[ -d /sys/firmware/efi ]] ||
        die "This finalization must be run in UEFI mode. /sys/firmware/efi is absent."

    [[ -d /sys/firmware/efi/efivars ]] ||
        die "EFI variable filesystem is not available at /sys/firmware/efi/efivars."

    [[ -w /sys/firmware/efi/efivars ]] ||
        die "EFI variable filesystem is not writable. Cannot create a UEFI boot entry."
}

uefi_loader_path() {
    local filename="$1"

    # efibootmgr expects a firmware-style path using backslashes.
    printf '\\EFI\\Slackware\\%s\n' "$filename"
}

uefi_boot_options() {
    local initrd_path="$1"
    local root_arg=''
    local fs_arg=''

    # Slackware's initrd is responsible for unlocking the encrypted root.
    #
    # If the initrd's rootdev is an absolute path, pass it through.  LVM
    # paths and /dev/mapper/luks<device> both work this way.
    #
    # If the initrd's rootdev is a bare name (for example "cryptroot"),
    # do NOT pass root=/dev/mapper/cryptroot: Slackware's init script would
    # derive a different mapper name (luks<device>) and then fail to find
    # the root device.  A bare rootdev is authoritative inside the initrd.
    if [[ "$INITRD_ROOTDEV" == /* ||
          "$INITRD_ROOTDEV" == UUID=* ||
          "$INITRD_ROOTDEV" == LABEL=* ]]; then
        root_arg="root=$INITRD_ROOTDEV "
    fi

    if [[ -n "$INITRD_ROOTFS" ]]; then
        fs_arg="rootfstype=$INITRD_ROOTFS "
    fi

    # initrd= is an EFI-stub kernel parameter and points at the file on the
    # ESP using a UEFI-style path.
    #
    # PREP_DISK_EXTRA_CMDLINE is an explicit escape hatch for additional
    # kernel parameters (console=, microcode, quiet, etc.).
    local extra="${PREP_DISK_EXTRA_CMDLINE:-}"

    printf '%s%srootflags=subvol=%s rw initrd=%s%s' \
        "$root_arg" \
        "$fs_arg" \
        "$BTRFS_ROOT_SUBVOL" \
        "$initrd_path" \
        "${extra:+ $extra}"
}

find_existing_uefi_entry() {
    local loader_path="$1"

    [[ -x "$(command -v efibootmgr)" ]] || return 1

    local output
    output=$(efibootmgr -v 2>/dev/null || true)

    [[ -n "$output" ]] || return 1

    # Match our exact label and kernel path.  Do NOT try to match the
    # optional data here: efibootmgr renders it as UCS-2 hex when stdout is
    # captured (a pipe/command substitution), even though it prints text on
    # a terminal.
    UEFI_MATCH_LABEL="$UEFI_BOOT_LABEL" \
    UEFI_MATCH_LOADER="$loader_path" \
    awk '
        /^Boot[0-9A-Fa-f]{4}/ {
            if (index($0, ENVIRON["UEFI_MATCH_LABEL"]) &&
                index($0, ENVIRON["UEFI_MATCH_LOADER"])) {
                boot=$1
                sub(/^Boot/, "", boot)
                sub(/\*.*/, "", boot)
                print boot
                exit
            }
        }
        ' <<< "$output"
}

list_managed_uefi_entries() {
    local loader_path="$1"

    efibootmgr -v 2>/dev/null |
        UEFI_MATCH_LABEL="$UEFI_BOOT_LABEL" \
        UEFI_MATCH_LOADER="$loader_path" \
        awk '
            /^Boot[0-9A-Fa-f]{4}/ {
                if (index($0, ENVIRON["UEFI_MATCH_LABEL"]) &&
                    index($0, ENVIRON["UEFI_MATCH_LOADER"])) {
                    boot=$1
                    sub(/^Boot/, "", boot)
                    sub(/\*.*/, "", boot)
                    print boot
                }
            }
        ' || true
}

remove_stale_managed_uefi_entries() {
    local keep_bootnum="${1:-}"

    local output
    output=$(efibootmgr -v 2>/dev/null) ||
        die "Could not inspect existing UEFI boot entries."

    local bootnum

    while IFS= read -r bootnum; do
        [[ -n "$bootnum" ]] || continue
        [[ "$bootnum" != "$keep_bootnum" ]] || continue

        log "Removing stale prep_disk.sh UEFI entry: Boot$bootnum"

        run_cmd efibootmgr \
            --bootnum "$bootnum" \
            --delete-bootnum

    done < <(
        UEFI_MATCH_LABEL="$UEFI_BOOT_LABEL" \
        awk '
            /^Boot[0-9A-Fa-f]{4}/ {
                if (index($0, ENVIRON["UEFI_MATCH_LABEL"])) {
                    boot=$1
                    sub(/^Boot/, "", boot)
                    sub(/\*.*/, "", boot)
                    print boot
                }
            }
            ' <<< "$output"
    )
}

ensure_uefi_boot_order() {
    local bootnum="$1"
    local current=''
    local present=''
    local new="$bootnum"
    local item

    [[ -n "$bootnum" ]] || return 0

    present=$(
        efibootmgr 2>/dev/null |
            awk '
                /^Boot[0-9A-Fa-f]{4}/ {
                    boot=$1
                    sub(/^Boot/, "", boot)
                    sub(/\*.*/, "", boot)
                    print boot
                }
            '
    )

    current=$(
        efibootmgr 2>/dev/null |
            awk -F': *' '/^BootOrder:/ { print $2; exit }'
    )

    if [[ -n "$current" ]]; then
        local -a items=()
        IFS=',' read -r -a items <<< "$current"

        for item in "${items[@]}"; do
            [[ -n "$item" ]] || continue
            [[ "$item" == "$bootnum" ]] && continue
            grep -Fxq "$item" <<< "$present" || continue
            new+=",$item"
        done
    fi

    if efibootmgr --bootorder "$new" >/dev/null 2>&1; then
        log "BootOrder now starts with Boot$bootnum."
    else
        warn "Could not put Boot$bootnum first in BootOrder."
    fi
}

create_uefi_boot_entry() {
    local disk="$1"
    local esp_partition_number="$2"
    local kernel_dest="$3"
    local initrd_dest="$4"

    require_uefi_runtime

    local kernel_filename
    kernel_filename=$(basename "$kernel_dest")

    local initrd_filename
    initrd_filename=$(basename "$initrd_dest")

    local loader_path
    loader_path=$(uefi_loader_path "$kernel_filename")

    local initrd_path
    initrd_path=$(uefi_loader_path "$initrd_filename")

    local options
    options=$(uefi_boot_options "$initrd_path")

    log
    log "============================================================"
    log " Direct UEFI kernel boot entry"
    log "============================================================"
    log
    log "Boot label : $UEFI_BOOT_LABEL"
    log "Disk       : $disk"
    log "ESP part   : $esp_partition_number"
    log "Kernel     : $loader_path"
    log "Initrd     : $initrd_path"
    log "Options    : $options"
    log

    local before
    before=$(list_managed_uefi_entries "$loader_path")

    # Always create a fresh entry.  efibootmgr does not expose the optional
    # data as text when captured, so an old entry cannot be safely assumed
    # to carry the current kernel command line.  The old entry is deleted
    # after the new one exists, so a failed create does not lose the boot path.
    log "Creating UEFI firmware boot entry..."

    run_cmd efibootmgr \
        --create \
        --disk "$disk" \
        --part "$esp_partition_number" \
        --label "$UEFI_BOOT_LABEL" \
        --loader "$loader_path" \
        --unicode "$options"

    local after
    after=$(list_managed_uefi_entries "$loader_path")

    local created=''
    local bootnum

    for bootnum in $after; do
        grep -Fxq "$bootnum" <<< "$before" && continue
        created="$bootnum"
        break
    done

    # If the list did not change, give the firmware/driver a moment and
    # re-check before giving up.  Do not fall back to "first matching
    # entry": with old entries still present that could keep the wrong one.
    if [[ -z "$created" ]]; then
        sleep 1
        after=$(list_managed_uefi_entries "$loader_path")

        for bootnum in $after; do
            grep -Fxq "$bootnum" <<< "$before" && continue
            created="$bootnum"
            break
        done
    fi

    [[ -n "$created" ]] ||
        die "efibootmgr completed but the new UEFI boot entry could not be identified."

    # Remove this helper's older entries (old kernel filename, old initrd
    # path, or old command line) now that the replacement exists.
    remove_stale_managed_uefi_entries "$created"
    ensure_uefi_boot_order "$created"

    log
    log "UEFI boot entry created:"
    log "    Boot$created"
    log "    $UEFI_BOOT_LABEL"
    log "    $loader_path"
    log
    log "UEFI boot entry verification: PASS"
}

verify_uefi_boot_entry() {
    local kernel_dest="$1"

    require_uefi_runtime

    local kernel_filename
    kernel_filename=$(basename "$kernel_dest")

    local loader_path
    loader_path=$(uefi_loader_path "$kernel_filename")

    local bootnum
    bootnum=$(find_existing_uefi_entry "$loader_path" || true)

    [[ -n "$bootnum" ]] ||
        die "Expected UEFI boot entry not found for $loader_path."

    log "Verified UEFI firmware entry:"
    log "    Boot$bootnum"
    log "    $UEFI_BOOT_LABEL"
    log "    $loader_path"
}

# ============================================================
# KERNEL / INITRD FINALIZATION
# ============================================================

# =============================================================================
# Initrd verification is performed by inspect_installed_boot(), called from
# finalize_installation() before /etc/crypttab is written.  The triple
# passphrase prompt seen historically (repair-crypt-boot.sh) was caused by
# crypttab and the initrd disagreeing about the LUKS mapper name:
#
#   1. crypttab had name "cryptlvm"
#   2. the initrd created "luksmmcblk0p2"
#   3. the kernel root= value named yet another path
#
# Stage 2 therefore reads rootdev, luksdev, and rootfs from the installed
# initrd, derives the mapper name Slackware's init script will create, and
# writes crypttab and the kernel command line to match it.
# =============================================================================

verify_kernel_initrd_on_esp() {
    local disk="$1"

    log
    log "============================================================"
    log " Kernel/initrd verification"
    log "============================================================"
    log

    [[ -n "$KERNEL_SOURCE" && -n "$INITRD_SOURCE" ]] ||
        die "Internal error: installed boot files were not inspected."

    verify_efi_stub_kernel "$KERNEL_SOURCE"

    local kernel_dest
    kernel_dest="${TARGET_ESP}/EFI/Slackware/$(basename "$KERNEL_SOURCE")"

    local initrd_dest
    initrd_dest="${TARGET_ESP}/EFI/Slackware/$(basename "$INITRD_SOURCE")"

    ensure_file_on_esp \
        "$KERNEL_SOURCE" \
        "$kernel_dest" \
        "Kernel"

    ensure_file_on_esp \
        "$INITRD_SOURCE" \
        "$initrd_dest" \
        "Initrd"

    [[ -f "$kernel_dest" ]] ||
        die "Kernel not present on ESP after copy."

    [[ -f "$initrd_dest" ]] ||
        die "Initrd not present on ESP after copy."

    cmp -s "$INITRD_SOURCE" "$initrd_dest" ||
        die "Initrd on ESP does not match the installed initrd."

    verify_efi_stub_kernel "$kernel_dest"

    run_cmd sync

    local initrd_path
    initrd_path=$(uefi_loader_path "$(basename "$initrd_dest")")

    local options
    options=$(uefi_boot_options "$initrd_path")

    create_uefi_boot_entry \
        "$disk" \
        1 \
        "$kernel_dest" \
        "$initrd_dest"

    verify_uefi_boot_entry "$kernel_dest"
}

verify_boot_installation() {
    local disk="$1"
    local kernel_dest initrd_dest loader bootnum order first

    log
    log "============================================================"
    log " Boot installation verification"
    log "============================================================"
    log

    [[ -n "$KERNEL_SOURCE" && -n "$INITRD_SOURCE" ]] ||
        die "Internal error: installed kernel/initrd paths were not inspected."

    kernel_dest="${TARGET_ESP}/EFI/Slackware/$(basename -- "$KERNEL_SOURCE")"
    initrd_dest="${TARGET_ESP}/EFI/Slackware/$(basename -- "$INITRD_SOURCE")"

    [[ -f "$kernel_dest" ]] ||
        die "Kernel is not installed on the ESP: $kernel_dest"

    [[ -f "$initrd_dest" ]] ||
        die "Initrd is not installed on the ESP: $initrd_dest"

    cmp -s -- "$KERNEL_SOURCE" "$kernel_dest" ||
        die "Kernel on the ESP does not match $KERNEL_SOURCE."

    cmp -s -- "$INITRD_SOURCE" "$initrd_dest" ||
        die "Initrd on the ESP does not match $INITRD_SOURCE."

    verify_efi_stub_kernel "$kernel_dest"

    initrd_quick_check "$initrd_dest" ||
        die "Initrd on the ESP is not usable for this LUKS/Btrfs layout: $initrd_dest"

    log "Disk          : $disk"
    log "Kernel on ESP : $kernel_dest"
    log "Initrd on ESP : $initrd_dest"

    loader=$(uefi_loader_path "$(basename -- "$kernel_dest")")

    bootnum=$(find_existing_uefi_entry "$loader" || true)

    [[ -n "$bootnum" ]] ||
        die "No UEFI firmware boot entry references $loader."

    order=$(efibootmgr 2>/dev/null |
        awk -F': *' '/^BootOrder:/ { print $2; exit }')

    first="${order%%,*}"

    [[ "$first" == "$bootnum" ]] ||
        die "UEFI BootOrder does not start with Boot$bootnum (BootOrder=$order)."

    log "UEFI entry    : Boot$bootnum ($UEFI_BOOT_LABEL)"
    log "UEFI loader   : $loader"
    log "BootOrder     : $order"
    log
    log "Boot installation verification: PASS"
}

# ============================================================
# SNAPSHOTS
# ============================================================

create_initial_snapshots() {
    local mapper="$1"

    log
    log "============================================================"
    log " Initial Btrfs snapshots"
    log "============================================================"
    log

    verify_prepared_target \
        "$mapper" \
        "${CFG[ROOT_SUBVOL]}" \
        "${CFG[HOME_SUBVOL]}" \
        "${CFG[ESP_PARTITION]}"

    run_cmd sync

    local stamp
    stamp=$(date '+%Y-%m-%d_%H-%M-%S')

    local root_name
    root_name=$(snapshot_name "$BTRFS_ROOT_SUBVOL" "$stamp")

    local home_name
    home_name=$(snapshot_name "$BTRFS_HOME_SUBVOL" "$stamp")

    mount_btrfs_top "$mapper"

    local root_dest="${MOUNT_TOP}/${root_name}"
    local home_dest="${MOUNT_TOP}/${home_name}"

    [[ ! -e "$root_dest" ]] ||
        die "Snapshot destination already exists: $root_dest"

    [[ ! -e "$home_dest" ]] ||
        die "Snapshot destination already exists: $home_dest"

    run_cmd btrfs subvolume snapshot \
        -r \
        "$TARGET_ROOT" \
        "$root_dest"

    CREATED_SNAPSHOTS+=("$root_dest")

    verify_readonly_snapshot "$root_dest"

    run_cmd btrfs subvolume snapshot \
        -r \
        "${TARGET_ROOT}/home" \
        "$home_dest"

    CREATED_SNAPSHOTS+=("$home_dest")

    verify_readonly_snapshot "$home_dest"

    run_cmd sync

    # Release the top-level mount; the snapshots are part of the filesystem
    # and remain visible through any later top-level mount.
    run_cmd umount "$MOUNT_TOP"
    forget_mount "$MOUNT_TOP"

    log
    log "Created:"
    log "    $root_name"
    log "    $home_name"
}

# ============================================================
# STAGE 2 — FINALIZATION
# ============================================================

finalize_installation() {
    local disk="$1"
    local metadata="$2"

    parse_config "$metadata"
    validate_metadata "$disk"
    verify_prepared_disk "$disk"

    local esp="${CFG[ESP_PARTITION]}"
    local root_partition="${CFG[ROOT_PARTITION]}"
    local mapper="/dev/mapper/${CFG[LUKS_NAME]}"

    log
    log "Preparation metadata verified:"
    log "    Disk       : ${CFG[DISK]}"
    log "    ESP UUID   : ${CFG[ESP_UUID]}"
    log "    LUKS UUID  : ${CFG[LUKS_UUID]}"
    log "    Btrfs UUID : ${CFG[BTRFS_UUID]}"
    log "    Checksum   : ${CFG[BTRFS_CHECKSUM]}"
    log "    Mapper     : $mapper"
    log "    Boot       : direct UEFI kernel"
    log

    if mapper_exists "${CFG[LUKS_NAME]}"; then
        verify_mapper \
            "$root_partition" \
            "${CFG[LUKS_NAME]}" \
            "${CFG[LUKS_UUID]}"
    else
        open_luks_interactive \
            "$root_partition" \
            "${CFG[LUKS_NAME]}"

        verify_mapper \
            "$root_partition" \
            "${CFG[LUKS_NAME]}" \
            "${CFG[LUKS_UUID]}"
    fi

    verify_btrfs \
        "$mapper" \
        "${CFG[BTRFS_UUID]}"

    mount_btrfs_top "$mapper"

    verify_subvolume \
        "$MOUNT_TOP" \
        "${CFG[ROOT_SUBVOL]}"

    verify_subvolume \
        "$MOUNT_TOP" \
        "${CFG[HOME_SUBVOL]}"

    ensure_default_subvolume \
        "$MOUNT_TOP" \
        "${CFG[ROOT_SUBVOL]}"

    run_cmd umount "$MOUNT_TOP"
    forget_mount "$MOUNT_TOP"

    mount_prepared_target \
        "$mapper" \
        "${CFG[ROOT_SUBVOL]}" \
        "${CFG[HOME_SUBVOL]}" \
        "$esp"

    verify_prepared_target \
        "$mapper" \
        "${CFG[ROOT_SUBVOL]}" \
        "${CFG[HOME_SUBVOL]}" \
        "$esp"

    local target_root
    target_root=$(determine_target_root)

    log
    log "Installed Slackware root:"
    log "    $target_root"
    log

    # Read the installed initrd before writing crypttab: Slackware's init
    # chooses the LUKS mapper name itself, and rc.luks must use that same
    # name or it will prompt for the passphrase a second time.
    inspect_installed_boot "$target_root"

    # Verify the firmware environment before touching installed config.
    require_uefi_runtime

    # =====================================================================
    # FUTURE ENHANCEMENT TODO:
    #
    # FIREWALL SCRIPT INTEGRATION (BEFORE SNAPSHOTS):
    #
    # At this point, before creating initial read-only Btrfs snapshots,
    # users may optionally enable a firewall script. This should happen
    # here because:
    #   - Snapshots represent a baseline system state
    #   - Including firewall configuration ensures security from first boot
    #   - Changes made after snapshotting don't affect the baseline
    #
    # Proposed flow:
    #   1. Check for --enable-firewall flag or prompt user
    #   2. Present curated firewall script options (simple iptables, nftables)
    #   3. Apply chosen firewall configuration
    #   4. Then proceed to snapshot creation
    #
    # This ensures the baseline snapshot includes network hardening.
    # =====================================================================

    # Generate the managed fstab block from verified metadata.  The prepared
    # copy on the ESP is advisory; regenerating here cannot go stale.
    local fstab_contents
    fstab_contents=$(cat <<EOF
# Generated by $PROGRAM $VERSION.
#
# EFI System Partition
UUID=${CFG[ESP_UUID]}    /boot/efi    vfat    defaults    0    0

# Btrfs root
UUID=${CFG[BTRFS_UUID]}    /    btrfs    subvol=${CFG[ROOT_SUBVOL]},compress=zstd    0    0

# Btrfs home
UUID=${CFG[BTRFS_UUID]}    /home    btrfs    subvol=${CFG[HOME_SUBVOL]},compress=zstd    0    0
EOF
)

    # The crypttab entry cannot be written during Stage 1: the mapper name
    # Slackware's initrd will use is only knowable after the initrd exists.
    local crypttab_contents
    crypttab_contents=$(cat <<EOF
# Generated by $PROGRAM $VERSION.
# This file is imported into the managed crypttab block.

$BOOT_LUKS_NAME    UUID=${CFG[LUKS_UUID]}    none    luks
EOF
)

    local fstab="${target_root}/etc/fstab"
    local crypttab="${target_root}/etc/crypttab"

    [[ -f "$fstab" ]] ||
        die "Installed fstab does not exist: $fstab"

    # Slackware's setup does not always create /etc/crypttab when the root
    # was already unlocked by the installation environment.  Create it if
    # the installer omitted it; replace_managed_block handles a new file.
    if [[ ! -f "$crypttab" ]]; then
        log "Installed /etc/crypttab is missing; creating it."
        [[ -d "${target_root}/etc" ]] ||
            die "Installed /etc directory does not exist: ${target_root}/etc"
        write_file "$crypttab" '' 0600
    fi

    replace_managed_block \
        "$fstab" \
        '# BEGIN prep_disk.sh fstab' \
        '# END prep_disk.sh fstab' \
        "$fstab_contents" \
        0644

    replace_managed_block \
        "$crypttab" \
        '# BEGIN prep_disk.sh crypttab' \
        '# END prep_disk.sh crypttab' \
        "$crypttab_contents" \
        0600

    strip_conflicting_fstab_entries "$fstab"
    strip_conflicting_crypttab_entries \
        "$crypttab" \
        "$BOOT_LUKS_NAME" \
        "${CFG[LUKS_UUID]}" \
        "${CFG[ROOT_PARTITION]}"

    run_cmd sync

    # The following operations are deliberately NOT performed here:
    #
    #     lilo/elilo      # not used in direct-kernel boot
    #     grub-install    # not used in direct-kernel boot
    #
    # mkinitrd IS run above (through ensure_installed_initrd) when the
    # installed system has no initrd or has one that cannot reach the
    # prepared LUKS/Btrfs root.

    verify_kernel_initrd_on_esp "$disk"

    # Final, explicit check of everything that is needed to reboot into
    # the installed system: kernel, initrd, and UEFI boot-menu entry.
    verify_boot_installation "$disk"

    create_initial_snapshots "$mapper"

    log
    log "============================================================"
    log " Finalization complete"
    log "============================================================"
    log
    log "Updated:"
    log "    ${target_root}/etc/fstab"
    log "    ${target_root}/etc/crypttab"
    log
    log "Boot mapper (from initrd):"
    log "    $BOOT_LUKS_NAME"
    log
    log "Initrd root device:"
    log "    $INITRD_ROOTDEV"
    log
    log "Kernel/initrd:"
    log "    ${TARGET_ESP}/EFI/Slackware/"
    log
    log "Boot method:"
    log "    UEFI firmware -> EFI-stub Linux kernel"
    log
    log "Traditional bootloader:"
    log "    NOT INSTALLED"
    log "    LILO/ELILO/GRUB NOT USED"
    log
    log "UEFI firmware boot entry:"
    log "    CREATED/VERIFIED"
    log "    Label: $UEFI_BOOT_LABEL"
    log
    log "EFI NVRAM:"
    log "    INTENTIONALLY MODIFIED"
    log "    via efibootmgr"
    log
    log "Initial read-only snapshots created."
    log
    log "================================================================"
    log " BOOT TROUBLESHOOTING NOTE:"
    log "================================================================"
    log " If boot prompts for LUKS passphrase multiple times:"
    log "   1. Do not panic - this indicates crypttab/initrd mismatch"
    log "   2. Boot from rescue media"
    log "   3. Extract initrd and check luksdev/rootdev files"
    log "   4. Rebuild initrd with correct parameters if needed"
    log "   5. Reference repair-crypt-boot.sh for working example"
    log "================================================================"
    log
    log "Root remains mounted at:"
    log "    $TARGET_ROOT"
    log
    log "Home remains mounted at:"
    log "    ${TARGET_ROOT}/home"
    log
    log "ESP remains mounted at:"
    log "    $TARGET_ESP"
    log

    SUCCESS=1
}

# ============================================================
# DRY RUN
# ============================================================

dry_run() {
    local disk="$1"

    local esp
    esp=$(partition_path "$disk" 1)

    local root
    root=$(partition_path "$disk" 2)

    log
    log "============================================================"
    log " $PROGRAM dry run"
    log "============================================================"
    log
    log "Version : $VERSION"
    log "Disk    : $disk"
    log
    log "NO CHANGES WILL BE MADE."
    log
    log "Boot design:"
    log "    direct UEFI -> EFI-stub kernel"
    log "    no LILO / ELILO / GRUB"
    log

    lsblk \
        -o NAME,SIZE,TYPE,FSTYPE,PARTTYPE,UUID,MOUNTPOINT \
        "$disk"

    log
    log "Expected:"
    log "    ESP : $esp"
    log "    LUKS: $root"
    log

    if disk_is_unmounted "$disk"; then
        log "Mounted-state check: PASS"
    else
        log "Mounted-state check: FAIL"
    fi

    log
    log "Preparation would execute:"
    log

    if command_exists wipefs; then
        log_cmd wipefs -a "$disk"
    fi

    log_cmd sgdisk \
        --zap-all \
        "$disk"

    log_cmd sgdisk \
        --new=1:1M:+$ESP_SIZE \
        --typecode=1:EF00 \
        --change-name=1:EFI \
        --new=2:0:0 \
        --typecode=2:"$ROOT_TYPE_GUID" \
        --change-name=2:cryptroot \
        "$disk"

    log_cmd mkfs.fat \
        -F 32 \
        -n EFI \
        "$esp"

    log_cmd cryptsetup \
        luksFormat \
        --type luks2 \
        --batch-mode \
        --key-file - \
        "$root"

    log_cmd cryptsetup \
        open \
        --type luks2 \
        --key-file - \
        "$root" \
        "$LUKS_NAME"

    log_cmd mkfs.btrfs \
        -f \
        --checksum "$BTRFS_CHECKSUM" \
        "/dev/mapper/$LUKS_NAME"

    log
    log "Subvolumes:"
    log "    $BTRFS_ROOT_SUBVOL"
    log "    $BTRFS_HOME_SUBVOL"
    log
    log "Finalization will create:"
    log "    UEFI NVRAM entry: $UEFI_BOOT_LABEL"
    log "    loader: \\EFI\\Slackware\\<kernel>"
    log "    initrd: \\EFI\\Slackware\\<initrd>"
    log "    root: derived from the installed initrd's rootdev"
    log "    rootflags: subvol=$BTRFS_ROOT_SUBVOL"
    log
    log "efibootmgr will be required during actual finalization."
}

# ============================================================
# CLEANUP
# ============================================================

remove_snapshot() {
    local path="$1"

    [[ -e "$path" ]] || return 0

    (( DRY_RUN )) && return 0

    btrfs subvolume delete "$path" 2>/dev/null ||
        warn "Could not remove incomplete snapshot: $path"
}

cleanup() {
    (( SUCCESS )) && return 0
    (( DRY_RUN )) && return 0

    local i target

    # Remove snapshots first.
    for (( i=${#CREATED_SNAPSHOTS[@]}-1; i>=0; i-- )); do
        remove_snapshot "${CREATED_SNAPSHOTS[$i]}" || true
    done

    # Only unmount paths explicitly mounted by this invocation.
    for (( i=${#CREATED_MOUNTS[@]}-1; i>=0; i-- )); do
        target="${CREATED_MOUNTS[$i]}"

        [[ -n "$target" ]] || continue

        if is_mounted "$target"; then
            umount "$target" 2>/dev/null || true
        fi
    done

    if (( LUKS_OPENED_BY_US )) &&
       mapper_exists "$LUKS_NAME"; then
        cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    fi

    if [[ -n "$METADATA_TMP" && -f "$METADATA_TMP" ]]; then
        rm -f -- "$METADATA_TMP" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ============================================================
# ENVIRONMENT
# ============================================================

require_root() {
    [[ "$EUID" -eq 0 ]] ||
        die "This program must be run as root."
}

require_commands() {
    local commands=(
        lsblk
        blkid
        sgdisk
        cryptsetup
        mkfs.fat
        mkfs.btrfs
        btrfs
        mount
        umount
        findmnt
        sync
        awk
        sed
        cp
        cpio
        zcat
        xzcat
        bzcat
        chroot
        ln
        findfs
        mktemp
        tail
        cmp
        readlink
        date
        od
    )

    local command_name

    for command_name in "${commands[@]}"; do
        command_exists "$command_name" ||
            die "Required command missing: $command_name"
    done
}

# ============================================================
# INSTALLER-IMAGE BUILDER
# ============================================================

parse_builder_arguments() {
    while (( $# )); do
        case "$1" in
            --make-installer|--build-installer)
                shift
                ;;

            --dry-run)
                DRY_RUN=1
                shift
                ;;

            --mirror)
                [[ $# -ge 2 ]] || die "--mirror requires a URL."
                B_MIRROR="$2"
                shift 2
                ;;

            --workdir)
                [[ $# -ge 2 ]] || die "--workdir requires a directory."
                B_WORKDIR="$2"
                shift 2
                ;;

            --output)
                [[ $# -ge 2 ]] || die "--output requires a filename."
                B_OUTPUT="$2"
                shift 2
                ;;

            --series)
                [[ $# -ge 2 ]] || die "--series requires a list."
                B_SERIES="$2"
                shift 2
                ;;

            --size)
                [[ $# -ge 2 ]] || die "--size requires a value."
                B_SIZE="$2"
                shift 2
                ;;

            --device)
                [[ $# -ge 2 ]] || die "--device requires a whole disk."
                B_DEVICE="$2"
                shift 2
                ;;

            --iso-only)
                B_ISO_ONLY=1
                shift
                ;;

            --no-rsync)
                B_NO_RSYNC=1
                shift
                ;;

            --verify)
                B_VERIFY=1
                shift
                ;;

            --keep)
                B_KEEP=1
                shift
                ;;

            --force)
                B_FORCE=1
                shift
                ;;

            --help|-h)
                usage
                exit 0
                ;;

            --version)
                printf '%s %s\n' "$PROGRAM" "$VERSION"
                exit 0
                ;;

            *)
                die "Unknown installer-build option: $1"
                ;;
        esac
    done
}

require_builder_commands() {
    local commands=(
        rsync
        xorriso
        cpio
        xz
        xzcat
        gzip
        zcat
        tar
        truncate
        dd
        mkfs.fat
        mount
        umount
        sha256sum
        md5sum
        du
        stat
        find
        install
        od
    )

    local command_name

    for command_name in "${commands[@]}"; do
        command_exists "$command_name" ||
            die "Required installer-build command missing: $command_name"
    done
}

size_to_bytes() {
    local value="$1"

    case "$value" in
        *[Gg]) printf '%s\n' $(( ${value%[Gg]} * 1024 * 1024 * 1024 )) ;;
        *[Mm]) printf '%s\n' $(( ${value%[Mm]} * 1024 * 1024 )) ;;
        *[Kk]) printf '%s\n' $(( ${value%[Kk]} * 1024 )) ;;
        *[0-9]) printf '%s\n' "$value" ;;
        *) return 1 ;;
    esac
}

find_isohdpfx() {
    local tree="$1"
    local candidate
    local package
    local output="$B_WORKDIR/isohdpfx.bin"

    for candidate in \
        /usr/share/syslinux/isohdpfx.bin \
        /usr/lib/syslinux/bios/isohdpfx.bin \
        /usr/lib/syslinux/isohdpfx.bin; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    package=$(find "$tree/slackware64" -maxdepth 2 -type f -name 'syslinux-*.txz' 2>/dev/null | head -n 1)

    [[ -n "$package" ]] || return 1

    tar -xJOf "$package" usr/share/syslinux/isohdpfx.bin > "$output" 2>/dev/null || return 1

    [[ -s "$output" ]] || return 1

    printf '%s\n' "$output"
}

inject_helper_into_initrd() {
    local initrd="$1"
    local tree="$B_WORKDIR/initrd-tree"
    local magic
    local temporary="${initrd}.new.$$"

    [[ -f "$initrd" ]] || die "Installer initrd not found: $initrd"

    rm -rf -- "$tree"
    mkdir -p -- "$tree"

    magic=$(od -An -tx1 -N6 -- "$initrd" 2>/dev/null | tr -d '[:space:]')

    log "Unpacking installer initrd..."
    case "$magic" in
        fd377a585a00*)
            ( set -o pipefail; xz -dc -- "$initrd" | ( cd "$tree" && cpio -idmu --quiet ) ) ||
                die "Could not unpack the installer initrd."
            ;;
        1f8b*)
            ( set -o pipefail; gzip -dc -- "$initrd" | ( cd "$tree" && cpio -idmu --quiet ) ) ||
                die "Could not unpack the installer initrd."
            ;;
        425a68*)
            ( set -o pipefail; bzip2 -dc -- "$initrd" | ( cd "$tree" && cpio -idmu --quiet ) ) ||
                die "Could not unpack the installer initrd."
            ;;
        303730373031*|303730373032*)
            ( cd "$tree" && cpio -idmu --quiet ) < "$initrd" ||
                die "Could not unpack the installer initrd."
            ;;
        *)
            die "Unrecognized initrd compression (magic: ${magic:-empty})."
            ;;
    esac

    [[ -f "$tree/usr/lib/setup/setup" ]] ||
        die "The unpacked initrd does not look like the Slackware installer (expected usr/lib/setup/setup). Microcode-prefixed initrds are not supported."

    # Some initrds rely entirely on devtmpfs.  Recreate the standard
    # early-console nodes if the archive did not provide them.
    mkdir -p "$tree/dev"
    local device name major minor
    for device in \
        console:5:1 null:1:3 zero:1:5 random:1:8 urandom:1:9 \
        tty1:4:1 tty2:4:2 tty3:4:3 tty4:4:4; do
        name="${device%%:*}"
        major="${device#*:}"
        major="${major%%:*}"
        minor="${device##*:}"

        if [[ ! -e "$tree/dev/$name" ]]; then
            mknod -m 600 "$tree/dev/$name" c "$major" "$minor" 2>/dev/null ||
                warn "Could not create /dev/$name in the initrd (continuing)."
        fi
    done

    log "Installing the helper into the installer initrd..."
    local helper_name
    helper_name=$(basename -- "$SELF")

    install -m 0755 -- "$SELF" "$tree/usr/lib/setup/$helper_name"

    # /usr/lib/setup is already on PATH in the installer (see
    # /etc/profile), exactly like the standard "setup" command.
    if [[ "$helper_name" != 'prep_disk' ]]; then
        ln -sfn "$helper_name" "$tree/usr/lib/setup/prep_disk"
    fi

    if [[ -f "$tree/etc/motd" ]] && ! grep -q 'prep_disk' "$tree/etc/motd"; then
        {
            printf '\n'
            printf 'Scriptware disk helper: type "prep_disk" (on PATH, like "setup").\n'
        } >> "$tree/etc/motd"
    fi

    log "Repacking installer initrd..."
    ( cd "$tree" && find . -print0 | cpio --null -o -H newc --quiet | xz -6 -T0 --check=crc32 > "$temporary" ) ||
        die "Could not repack the installer initrd."

    [[ -s "$temporary" ]] || die "Repacked initrd is empty."

    mv -f -- "$temporary" "$initrd"
    rm -rf -- "$tree"

    log "Helper embedded in installer initrd: /usr/lib/setup/prep_disk"
}

build_installer_iso() {
    local tree="$1"
    local output="$2"
    local isohdpfx
    local build_date

    isohdpfx=$(find_isohdpfx "$tree") ||
        die "Could not find isohdpfx.bin. Install syslinux or keep a syslinux package in the tree."

    build_date=$(date -u '+%d_%b_%Y' | tr '[:lower:]' '[:upper:]')

    # xorriso generates this; a stale copy in the tree confuses it.
    rm -f -- "$tree/isolinux/boot.cat"
    rm -f -- "$output"

    log "Building installer ISO..."
    ( cd "$tree" && xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -R -J \
        -A "SLACKWARE-CURRENT MINI INSTALL CD FOR X86_64 - BUILT ${build_date} - SCRIPTWARE" \
        -p "SCRIPTWARE PREP_DISK $VERSION" \
        -hide-rr-moved \
        -v -d -N \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "$isohdpfx" \
        -eltorito-alt-boot \
        -e isolinux/efiboot.img \
        -no-emul-boot -isohybrid-gpt-basdat \
        -m 'extra/' \
        -m 'pasture/' \
        -m 'patches/' \
        -m 'slackware/' \
        -m 'slackware64/' \
        -m 'source/' \
        -m 'testing/' \
        -m 'usb-and-pxe-installers/' \
        -volid SlackNetinst \
        -output "$output" \
        . ) || die "xorriso failed to build $output"
}

write_builder_readme() {
    local path="$1"

    cat > "$path" <<EOF
SCRIPTWARE USB - SLACKWARE-CURRENT OFFLINE INSTALLER
====================================================

Built by $PROGRAM $VERSION on $(date -u '+%Y-%m-%d %H:%M UTC').

This image contains:

    the Slackware-current installer
    /slackware64/              package tree (PREPUSB partition)
    /PACKAGES.TXT, /FILELIST.TXT, /CHECKSUMS.md5
    /extras/$(basename -- "$SELF")
    /extras/README.txt         this file

The disk helper is installed in the installer initrd as:

    /usr/lib/setup/prep_disk

That directory is on PATH in the installer just like the standard
"setup" command, so no partition needs to be mounted first:

    prep_disk --help
    prep_disk --dry-run /dev/nvme0n1
    prep_disk /dev/nvme0n1

The same helper is also available on the PREPUSB partition at
/extras/$(basename -- "$SELF"), and on the ISO at /extras/.

Typical workflow
----------------
Boot the image in UEFI mode.  At the installer shell, before setup:

    lsblk
    prep_disk --dry-run /dev/nvme0n1
    prep_disk /dev/nvme0n1

Then run the normal "setup" program, install from the PREPUSB partition,
do NOT format the ESP, and install the generic kernel.  Running MKINITRD
is optional: Stage 2 generates the initrd if it is missing or unsuitable.
Finally, before rebooting:

    prep_disk /dev/nvme0n1

Stage 2 generates the initrd if it is missing, copies the kernel and
initrd to the ESP, creates/verifies the UEFI boot entry, and verifies
everything before reporting success.
EOF
}

build_prepusb_image() {
    local tree="$1"
    local output="$2"
    local size="$3"
    local bytes
    local need
    local mountpoint="$B_WORKDIR/prepusb-mnt"
    local series

    if [[ "$size" == 'auto' ]]; then
        need=$(du -sb -- "$tree/slackware64" | awk '{print $1}')
        [[ -n "$need" ]] || die "Could not determine the package tree size."

        # packages + metadata + extras + allocator slack
        bytes=$(( need + 512 * 1024 * 1024 ))
        bytes=$(( ((bytes + (1024 * 1024 * 1024) - 1) / (1024 * 1024 * 1024)) * (1024 * 1024 * 1024) ))
    else
        bytes=$(size_to_bytes "$size") ||
            die "Invalid --size value: $size (use e.g. 6G)."
    fi

    (( bytes >= 256 * 1024 * 1024 )) ||
        die "PREPUSB size is too small (minimum 256M)."

    log "Creating PREPUSB image (${bytes} bytes)..."
    rm -f -- "$output"
    truncate -s "$bytes" "$output"
    mkfs.fat -F 32 -n PREPUSB "$output" >/dev/null

    mkdir -p -- "$mountpoint"
    mount -o loop "$output" "$mountpoint" ||
        die "Could not loop-mount $output."
    record_mount "$mountpoint"

    log "Copying packages to PREPUSB..."
    if [[ -n "$B_SERIES" ]]; then
        mkdir -p "$mountpoint/slackware64"
        for series in $B_SERIES; do
            cp -a -- "$tree/slackware64/$series" "$mountpoint/slackware64/" ||
                die "Could not copy series $series."
        done
    else
        cp -a -- "$tree/slackware64" "$mountpoint/" ||
            die "Could not copy the package tree."
    fi

    for need in PACKAGES.TXT FILELIST.TXT CHECKSUMS.md5; do
        if [[ -f "$tree/$need" ]]; then
            cp -a -- "$tree/$need" "$mountpoint/" ||
                die "Could not copy $need."
        fi
    done

    mkdir -p "$mountpoint/extras"
    cp -a -- "$SELF" "$mountpoint/extras/" ||
        die "Could not copy the helper to PREPUSB."
    if [[ -f "$tree/extras/README.txt" ]]; then
        cp -a -- "$tree/extras/README.txt" "$mountpoint/extras/" ||
            die "Could not copy the README to PREPUSB."
    fi

    df -h "$mountpoint" || true
    sync

    umount "$mountpoint" || die "Could not unmount $mountpoint."
    forget_mount "$mountpoint"
    rmdir "$mountpoint" 2>/dev/null || true

    log "PREPUSB image created: $output"
}

write_le32() {
    local n="$1"

    printf "\\$(printf '%03o' $(( n & 255 )))"
    printf "\\$(printf '%03o' $(( (n >> 8) & 255 )))"
    printf "\\$(printf '%03o' $(( (n >> 16) & 255 )))"
    printf "\\$(printf '%03o' $(( (n >> 24) & 255 )))"
}

write_mbr_partition3() {
    local image="$1"
    local start="$2"
    local size="$3"
    local offset=$(( 446 + 2 * 16 ))

    {
        printf '\000\376\377\377\014\376\377\377'
        write_le32 "$start"
        write_le32 "$size"
    } | dd of="$image" bs=1 seek="$offset" conv=notrunc status=none ||
        die "Could not write the PREPUSB partition entry."
}

assemble_usb_image() {
    local iso="$1"
    local prepusb="$2"
    local output="$3"
    local iso_bytes
    local p3_bytes
    local iso_sectors
    local p3_sectors

    iso_bytes=$(stat -c %s -- "$iso")
    p3_bytes=$(stat -c %s -- "$prepusb")

    (( iso_bytes % 512 == 0 )) || die "ISO size is not 512-byte aligned."
    (( p3_bytes % 512 == 0 )) || die "PREPUSB size is not 512-byte aligned."

    iso_sectors=$(( iso_bytes / 512 ))
    p3_sectors=$(( p3_bytes / 512 ))

    rm -f -- "$output"
    cat -- "$iso" "$prepusb" > "$output" ||
        die "Could not assemble $output."

    write_mbr_partition3 "$output" "$iso_sectors" "$p3_sectors"
    sync

    log "USB image assembled: $output"
}

write_image_to_device() {
    local image="$1"
    local device="$2"
    local type

    [[ -b "$device" ]] || die "--device is not a block device: $device"

    type=$(lsblk -dno TYPE "$device" 2>/dev/null || true)
    [[ "$type" == 'disk' ]] ||
        die "--device must name a whole disk (detected type: ${type:-unknown})."

    if lsblk -rno MOUNTPOINT "$device" 2>/dev/null | grep -q '[^[:space:]]'; then
        die "$device or one of its partitions is mounted."
    fi

    log "About to overwrite $device with $image."
    confirm_yes "This destroys all data on $device. Continue?" ||
        die "Aborted."

    log "Writing image to $device..."
    dd if="$image" of="$device" bs=4M conv=fsync status=progress ||
        die "Writing to $device failed."

    sync
    log "Wrote $image to $device."
}

make_installer() {
    local tree
    local iso
    local prepusb

    (( DRY_RUN == 0 )) ||
        die "--dry-run is not supported with --make-installer."

    require_root
    require_builder_commands

    [[ -n "$B_WORKDIR" ]] || B_WORKDIR='/var/cache/scriptware'
    [[ -n "$B_OUTPUT" ]] ||
        B_OUTPUT="$PWD/slackware64-current-scriptware-$(date -u '+%Y%m%d').img"

    if (( B_ISO_ONLY )); then
        case "$B_OUTPUT" in
            *.iso) ;;
            *.img) B_OUTPUT="${B_OUTPUT%.img}.iso" ;;
            *)     B_OUTPUT="${B_OUTPUT}.iso" ;;
        esac
    fi

    tree="$B_WORKDIR/slackware64-current"
    iso="$B_WORKDIR/installer.iso"
    prepusb="$B_WORKDIR/prepusb.img"

    mkdir -p -- "$B_WORKDIR"

    if [[ -e "$B_OUTPUT" ]] && (( ! B_FORCE )); then
        die "Output already exists: $B_OUTPUT (use --force to overwrite)."
    fi

    if (( B_NO_RSYNC )); then
        [[ -d "$tree" ]] ||
            die "--no-rsync requested but $tree does not exist."
    else
        log "Mirroring $B_MIRROR"
        log "      -> $tree"

        rsync -rlptH --delete \
            --exclude 'source/' \
            --exclude 'usb-and-pxe-installers/' \
            --exclude 'extra/' \
            --exclude 'pasture/' \
            --exclude 'patches/' \
            --exclude 'testing/' \
            "$B_MIRROR/" "$tree/" ||
            die "rsync failed. Check the mirror URL and network."
    fi

    [[ -d "$tree/slackware64" ]] ||
        die "$tree does not contain slackware64/."
    [[ -f "$tree/isolinux/initrd.img" ]] ||
        die "$tree is missing isolinux/initrd.img."
    [[ -f "$tree/isolinux/isolinux.bin" ]] ||
        die "$tree is missing isolinux/isolinux.bin."
    [[ -f "$tree/isolinux/efiboot.img" ]] ||
        die "$tree is missing isolinux/efiboot.img."

    if (( B_VERIFY )); then
        log "Verifying CHECKSUMS.md5 (this can take a while)..."
        ( cd "$tree" && md5sum -c CHECKSUMS.md5 >/dev/null ) ||
            die "CHECKSUMS.md5 verification failed."
    fi

    inject_helper_into_initrd "$tree/isolinux/initrd.img"

    mkdir -p "$tree/extras"
    cp -a -- "$SELF" "$tree/extras/"
    write_builder_readme "$tree/extras/README.txt"

    build_installer_iso "$tree" "$iso"

    if (( B_ISO_ONLY )); then
        cp -f -- "$iso" "$B_OUTPUT"
        sha256sum "$B_OUTPUT" > "$B_OUTPUT.sha256"
        log "ISO created: $B_OUTPUT"
    else
        build_prepusb_image "$tree" "$prepusb" "$B_SIZE"
        assemble_usb_image "$iso" "$prepusb" "$B_OUTPUT"
        sha256sum "$B_OUTPUT" > "$B_OUTPUT.sha256"
        log "USB image created: $B_OUTPUT"
    fi

    if [[ -n "$B_DEVICE" ]]; then
        write_image_to_device "$B_OUTPUT" "$B_DEVICE"
    fi

    if (( ! B_KEEP )); then
        rm -f -- "$prepusb" "$iso"
    fi

    log
    log "Installer build complete."
    log "    Output  : $B_OUTPUT"
    log "    Checksum: $B_OUTPUT.sha256"
    log "    Helper  : prep_disk (installer initrd, on PATH like setup)"
}

# ============================================================
# ARGUMENTS
# ============================================================

usage() {
    cat <<EOF
Usage:

    $PROGRAM [--dry-run] /dev/sdX
    $PROGRAM [--dry-run] /dev/nvme0n1
    $PROGRAM [--dry-run] /dev/mmcblk0

    $PROGRAM --prepare /dev/sdX     (force Stage 1)

    $PROGRAM --make-installer [options]   (build an install image)

    $PROGRAM --help
    $PROGRAM --version

Options:

    --dry-run   Display intended preparation operations.
    --prepare   Force destructive Stage 1 even if an installed system is
                mounted at /mnt (normally refused).
    --help      Display this help.
    --version   Display program version.

Installer-image build options (--make-installer):

    --mirror URL    Slackware-current mirror root
                    (default: $B_MIRROR)
    --workdir DIR   Local mirror/build directory
                    (default: /var/cache/scriptware)
    --output FILE   Output image
                    (default: ./slackware64-current-scriptware-YYYYMMDD.img,
                     or .iso with --iso-only)
    --series LIST   Package series to include (default: full tree)
    --size SIZE     PREPUSB size, e.g. 6G (default: auto)
    --iso-only      Build only the hybrid installer ISO
    --no-rsync      Reuse an existing tree in --workdir
    --verify        Verify CHECKSUMS.md5 after rsync
    --device DISK   Write the finished image to a whole disk (destructive)
    --keep          Keep the intermediate ISO and PREPUSB files
    --force         Overwrite an existing output file

    The helper itself is installed into the installer's initrd at
    /usr/lib/setup/prep_disk, which is on PATH exactly like the standard
    "setup" command.  No ESP mount is needed to run it.

    --make-installer must be run as root.  It preserves the initrd's
    device nodes and loop-mounts the PREPUSB filesystem.  Build
    requirements: rsync, xorriso, cpio, xz, gzip, tar, mkfs.fat, and
    loop-mount support.

Environment:

    PREP_DISK_EXTRA_CMDLINE
                Extra kernel parameters appended to the direct EFI boot
                entry (for example "console=ttyS0,115200 quiet").

For disk modes, the argument MUST identify a whole disk.

Supported partition naming examples:

    /dev/sda       -> /dev/sda1
    /dev/vda       -> /dev/vda1
    /dev/xvda      -> /dev/xvda1
    /dev/nvme0n1   -> /dev/nvme0n1p1
    /dev/mmcblk0   -> /dev/mmcblk0p1
    /dev/loop0     -> /dev/loop0p1
    /dev/md0       -> /dev/md0p1

Behavior:

    No preparation metadata:
        Destructively prepare the disk.

    Preparation metadata present:
        Verify the prepared disk and perform installation
        finalization.

Finalization:

    - verifies GPT/LUKS2/Btrfs;
    - opens LUKS2 when necessary;
    - verifies @ and @home;
    - updates only prep_disk.sh-managed fstab/crypttab blocks;
    - generates the installed initrd with mkinitrd when missing or when
      it cannot reach the prepared LUKS/Btrfs root;
    - verifies/copies the installed kernel and initrd to the ESP;
    - verifies the kernel is a PE/COFF EFI-stub image;
    - creates/verifies a direct UEFI firmware boot entry;
    - verifies the kernel, initrd and UEFI entry before succeeding;
    - creates initial read-only Btrfs snapshots.

BOOT METHOD:

    UEFI firmware
        -> Linux kernel EFI stub
        -> initrd
        -> /dev/mapper/<mapper chosen by the initrd>
        -> Btrfs subvolume @
        -> /

This program does NOT:

    - install a bootloader;
    - install LILO;
    - install ELILO;
    - install GRUB;
    - configure LILO;
    - configure ELILO;
    - configure GRUB;
    - invoke lilo;
    - invoke elilo;
    - invoke grub-install;
    - invoke grub-mkconfig.

This program DOES:

    - invoke mkinitrd when the installed initrd is missing or cannot
      reach the prepared root;
    - invoke efibootmgr during finalization;
    - create/update its own UEFI Boot#### entry;
    - modify EFI NVRAM as required to create that entry.

Managed firmware entry:

    Label:
        $UEFI_BOOT_LABEL

The direct-kernel boot entry is necessary because merely copying an
EFI-stub kernel to the ESP does not necessarily create a selectable
UEFI firmware boot-menu item.

IMPORTANT: INITRD VERIFICATION (from repair-crypt-boot.sh experience):

    The Slackware installer's mkinitrd makes assumptions about storage.
    If prepared storage differs from what mkinitrd expects, boot fails
    with multiple LUKS passphrase prompts.

    Finalization automatically reads the installed initrd and verifies:
        luksdev  # must describe the encrypted root partition
        rootdev  # must name a device the Slackware init script will create
        rootfs   # must be btrfs

    It then writes /etc/crypttab and root= to match the initrd.  If the
    initrd is missing or unsuitable, finalization generates one with
    explicit mkinitrd flags, then verifies it again before proceeding.

    Manual inspection is still possible:
        mkdir -p /tmp/initrd && cd /tmp/initrd
        zcat /boot/initrd.gz | cpio -idmu
        cat luksdev
        cat rootdev
        cat rootfs

CRITICAL BOOT TROUBLESHOOTING:

    Multiple LUKS passphrase prompts = crypttab/initrd mismatch

    Resolution (see repair-crypt-boot.sh):
        1. Boot rescue media
        2. Inspect initrd's internal luksdev/rootdev files
        3. Rebuild initrd with correct -C (LUKS) and -r (root) flags
        4. Verify new initrd matches before rebooting

The installed Slackware initrd must contain the support necessary to
unlock the LUKS2 root and mount the Btrfs root filesystem.

================================================================================
                        FUTURE ENHANCEMENTS PLANNED
================================================================================

    --enable-lvm       Add LVM layer (recommended for Slackware compatibility)
    --disable-lvm      Skip LVM (current default)
    --swap-size=N      Create swap LV/partition of size N (e.g., 8G max)
    --no-swap          Rely on zRAM (Slackware current default)
    --esp-size=N       Set ESP size (default: 1G, min: 256M)
    --fs=TYPE          Filesystem: btrfs (default), ext4, xfs
    --checksum=ALGO    Btrfs checksum: xxhash (default), sha256, crc32c
    --subvols=LIST     Custom subvolume layout (@,@home by default)
    --enable-firewall  Enable curated firewall script before snapshots

    OPINIONATED POLICIES (even when implemented):
    - Swap size: matches RAM, max 8GB
    - ZSWAP: enabled with swap partitions, NOT with ZRAM
    - Firewall: only curated, well-tested scripts supported

These options are NOT YET IMPLEMENTED. Current version hardcodes single layout.
================================================================================
EOF
}

parse_arguments() {
    local device=''
    local arg

    for arg in "$@"; do
        case "$arg" in
            --help|-h)
                usage
                exit 0
                ;;

            --version)
                printf '%s %s\n' "$PROGRAM" "$VERSION"
                exit 0
                ;;

            --dry-run)
                DRY_RUN=1
                ;;

            --prepare|--force-prepare)
                FORCE_PREPARE=1
                ;;

            --*)
                die "Unknown option: $arg"
                ;;

            *)
                [[ -z "$device" ]] ||
                    die "Only one disk may be specified."

                device="$arg"
                ;;
        esac
    done

    [[ -n "$device" ]] ||
        die "Usage: $PROGRAM [--dry-run] /dev/sdX (use --make-installer to build an install image)"

    printf '%s\n' "$device"
}

# ============================================================
# MAIN
# ============================================================

main() {
    local arg

    # Handle these before command substitution: an exit inside
    # $(parse_arguments ...) would only exit the subshell.
    for arg in "$@"; do
        case "$arg" in
            --help|-h)
                usage
                exit 0
                ;;
            --version)
                printf '%s %s\n' "$PROGRAM" "$VERSION"
                exit 0
                ;;
            --dry-run)
                # parse_arguments runs in a command substitution below, so
                # its DRY_RUN assignment would not survive.  Set it here.
                DRY_RUN=1
                ;;
            --prepare|--force-prepare)
                # Destructive Stage 1 is refused by default when an installed
                # system is already mounted at /mnt.  This flag is the
                # deliberate override.
                FORCE_PREPARE=1
                ;;
            --make-installer|--build-installer)
                MAKE_INSTALLER=1
                ;;
        esac
    done

    if (( MAKE_INSTALLER )); then
        parse_builder_arguments "$@"
        make_installer
        exit 0
    fi

    local disk
    disk=$(parse_arguments "$@")

    require_root
    require_commands

    validate_disk_argument "$disk"
    set_luks_name "$disk"

    if (( DRY_RUN )); then
        dry_run "$disk"
        exit 0
    fi

    local esp
    esp=$(partition_path "$disk" 1)

    local metadata=''

    if (( ! FORCE_PREPARE )) &&
       [[ -b "$esp" ]] &&
       metadata=$(find_metadata_on_esp "$esp"); then
        # find_metadata_on_esp mounted the ESP only to locate the metadata.
        # Keep a private copy: the ESP is about to be mounted at its final
        # target location, which would otherwise make $metadata unreachable.
        METADATA_TMP=$(
            mktemp "${TMPDIR:-/tmp}/prep_disk_metadata.XXXXXX"
        ) || die "Could not create a temporary metadata file."

        cp -- "$metadata" "$METADATA_TMP" ||
            die "Could not copy preparation metadata."

        # find_metadata_on_esp runs inside a command substitution, so the
        # mount it created is not recorded in this shell's CREATED_MOUNTS.
        # It mounts the ESP read-only only to read the metadata; release it
        # before finalize_installation mounts the ESP read-write below.
        if is_mounted "$MOUNT_ESP"; then
            run_cmd umount "$MOUNT_ESP"
            forget_mount "$MOUNT_ESP"
        fi

        finalize_installation \
            "$disk" \
            "$METADATA_TMP"

        rm -f -- "$METADATA_TMP"
        METADATA_TMP=''

        exit 0
    fi

    # Detection failed, but find_metadata_on_esp may still have left its
    # private read-only ESP mount behind.  Release it before Stage 1.
    if is_mounted "$MOUNT_ESP"; then
        run_cmd umount "$MOUNT_ESP"
        forget_mount "$MOUNT_ESP"
    fi

    # Never silently repartition over what looks like an existing or
    # completed installation.  The usual cause of missing metadata is that
    # the Slackware installer reformatted the ESP, erasing
    # EFI/Slackware/prep_disk/.
    if (( ! FORCE_PREPARE )); then
        if [[ -f "${TARGET_ROOT}/etc/slackware-version" ||
              -f "${TARGET_ROOT}/etc/fstab" ]]; then
            die "An installed system appears to be mounted at ${TARGET_ROOT}, but no preparation metadata was found on the ESP. Refusing to repartition. Restore the ESP metadata, or re-run with --prepare to erase the disk deliberately."
        fi

        local existing_root
        existing_root=$(partition_path "$disk" 2)

        if [[ -b "$existing_root" ]]; then
            local existing_type
            existing_type=$(blkid -s TYPE -o value "$existing_root" 2>/dev/null || true)

            case "$existing_type" in
                crypto_LUKS|btrfs|LVM2_member|linux_raid_member|swap)
                    die "$existing_root already contains $existing_type data, but no preparation metadata was found on the ESP. Refusing to repartition. Re-run with --prepare to erase the disk deliberately."
                    ;;
            esac
        fi
    fi

    prepare_disk "$disk"
}
main "$@"
