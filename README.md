# Scriptware

Optional enhancement tools for Slackware Linux installations.

> Naming: the distributed file is `prep_disk-7.1.sh`; the program identifies
> itself as `prep_disk.sh` in logs and usage. Images built with
> `--make-installer` expose it as the command `prep_disk`, on `PATH` like
> `setup`.

## Position

Scriptware is an **opt-in addition** designed to reside alongside the official
Slackware installation media (e.g., in `/extras` on the ISO). It is NOT a
replacement for the standard Slackware setup utility.

- Optional: Users can ignore Scriptware and use the standard installer
- Augmentative: Works around the official installer, not instead of it
- Non-modifying: Does not alter official Slackware packages or behavior
- Preserves tradition: Respects Slackware's installation philosophy

If you don't use Scriptware, you get the standard Slackware installation.
If you do use it, you get encryption, firewall, and AI workstation tooling
on top of that foundation.

---

## Warning

**Designed for experienced Slackware administrators.**

These tools orchestrate encryption, firewall, and AI workstation setup around
the standard Slackware installer. Users should be comfortable with:

- Terminal-based workflows
- Disk partitioning and encryption (LUKS2)
- Filesystem management (Btrfs subvolumes, snapshots)
- System configuration (/etc/fstab, /etc/crypttab, initrd)
- Reading and understanding script behavior before execution

**Not suitable for beginners.** Review each script thoroughly before running.

---

## Philosophy

| Standard Slackware | Scriptware Enhancement |
|--------------------|------------------------|
| Unencrypted disks | LUKS2 transparent encryption |
| Manual partitioning | Automated GPT + Btrfs layout |
| No default firewall | nftables workstation firewall |
| Minimal dev environment | Agentic AI workspace bootstrap |
| User configures manually | Pre-configured dev tooling |

Both coexist. Scriptware does not touch official Slackware packages or
replace the `setup` utility.

---

## Distribution Model

Scriptware is intended for inclusion as optional extras on Slackware
installation media:

    slomo-16.0-x86_64-DVD.iso/
    ├── kernels/
    ├── extra/
    ├── testing/
    ├── ap/          (Official Slackware packages)
    ├── d/
    ├── e/
    ├── k/
    ├── kde/
    └── extras/      (Scriptware lives here - opt-in)
        ├── prep_disk.sh
        ├── bobs_basic_firestarter.sh
        ├── mr.clever.pl
        └── README.md

Users who don't care about Scriptware simply boot and run `setup` normally.
Users who want enhanced security or AI tooling run the Scriptware utilities
before or after the standard installer.

---

## Building Your Own Installer Image

On a normal Linux host (not the live installer), the helper can mirror
Slackware-current and build a fresh image with itself embedded in the
installer initrd:

    sudo ./prep_disk-7.1.sh --make-installer \
        --workdir /var/cache/scriptware \
        --output /var/cache/scriptware/scriptware.img

The resulting image boots the normal Slackware installer. In its shell,
`prep_disk` is on PATH exactly like `setup`:

    prep_disk --help
    prep_disk --dry-run /dev/nvme0n1

No ESP or PREPUSB mount is needed. The image also carries the usual
PREPUSB partition with the package tree and `/extras`.

---

## Runtime Requirements

**Critical:** Slackware's installer/live environment includes `bash` but may not include `perl`. Scripts designed for pre-install use must be bash-compatible.

| Script | Runs Where | Required Interpreter | Available in Installer? |
|--------|-----------|---------------------|-------------------------|
| `prep_disk.sh` | Live ISO / chroot | Bash | ✅ Guaranteed |
| `bobs_basic_firestarter.sh` | chroot | Bash + nftables | ✅ Guaranteed |
| `mr.clever.pl` | Post-login user shell | Perl | ✅ Installed system |

### Why This Matters

The disk preparation script (`prep_disk.sh`) runs from the **live installer environment**, before any installed system exists. Perl is typically not present in the live ISO, so pre-install scripts must be bash-only.

Post-install scripts (`mr.clever.pl`) run after reboot from your user shell, where Perl is reliably available.

---

## Installation Workflow

### Standard Slackware Path (No Scriptware)

    $ setup
    [Standard Slackware installation]

That's it. Scriptware is completely optional and can be ignored entirely.

### Enhanced Path (With Scriptware)

#### Step 1: Disk Preparation (Live Environment)
    sudo /extras/prep_disk.sh /dev/sda
    
    Creates:
    - GPT partition table
    - 1 GiB EFI System Partition
    - LUKS2 container (remaining disk)
    - Btrfs filesystem with @, @home subvolumes
    - Mounts target at /mnt (ready for installer)

#### Step 2: Standard Slackware Installer
    $ setup
    
    Use the official Slackware setup utility. Target /mnt as root.
    This is the OFFICIAL Slackware installer. Scriptware does NOT replace this step.

#### Step 3: Firewall Integration (Before Finalization)
    chroot /mnt
    /extras/bobs_basic_firestarter.sh
    exit
    
    Installs nftables rules into target system. This ensures the firewall
    is active on first boot.

#### Step 4: Installation Finalization (Live Environment)
    sudo /extras/prep_disk.sh /dev/sda
    
    Second invocation verifies disk layout, generates or inspects the
    installed initrd, merges configuration into the target system, creates
    the direct UEFI boot entry, and creates initial Btrfs snapshots.
    
    Leave mounted for the final boot-entry verification.

#### Step 5: Direct UEFI Boot Entry

    No traditional bootloader installation is required.

    Finalization generates or repairs the installed initrd when needed,
    copies the kernel and initrd to the ESP, and creates a direct UEFI
    firmware boot entry.  It deliberately does not install or configure
    LILO, ELILO, or GRUB.

    Secure Boot, if enabled, must be handled separately (disable it or sign
    the kernel).

#### Step 6: First Boot
    Boot into your new Slackware system with:
    - Full-disk encryption (LUKS2)
    - Btrfs root/home subvolumes
    - Active nftables firewall

#### Step 7: AI Workspace Setup (After First Login)
    /extras/mr.clever.pl --profile=agent
    
    Installs AI clients, CLI tools, and development environment in user
    space. No system package modifications.

---

## Scripts Reference

| Script | Role | When to Run | Destructive? | Privileges |
|--------|------|-------------|--------------|------------|
| `prep_disk.sh` (first) | Pre-installer disk preparation | Step 1 | Yes (full disk erase) | Root |
| Slackware setup | Main package installation | Step 2 | Standard installer behavior | Root |
| `bobs_basic_firestarter.sh` | Post-install hardening | Step 3 (via chroot) | No | Root |
| `prep_disk.sh` (second) | Post-install finalization | Step 4 | No (configuration only) | Root |
| `mr.clever.pl` | Post-boot workspace | Step 7 (after reboot) | No | Regular user |

---

## Detailed Usage

### Step 1: Disk Preparation

From Slackware live environment as root:

Preview operations (no changes made):
    /extras/prep_disk.sh --dry-run /dev/sda

Execute (DESTROYS ALL DATA on target disk):
    sudo /extras/prep_disk.sh /dev/sda

After this completes, /mnt, /mnt/home, and /mnt/boot/efi are ready for the installer.

### Step 2: Standard Slackware Installer

Run the official Slackware setup utility:
    $ setup

Use the official Slackware setup utility. Scriptware does not interfere with this step.

Important: Target /mnt as your installation root. The disk preparation script already
mounted the filesystems correctly.

Boot requirement: install the generic kernel. Running the installer's
MKINITRD step is optional: finalization generates the initrd if it is
missing and verifies that it contains LUKS and Btrfs support before
creating the boot entry.

Do NOT format the EFI System Partition during setup.  The preparation metadata
lives in EFI/Slackware/prep_disk on that partition; erasing it prevents
automatic finalization.

### Step 3: Firewall Integration

From live environment, chroot into installed system:
    sudo mount /dev/mapper/lukssda2 /mnt       # If not already mounted
    chroot /mnt

Inside chroot, install firewall:
    /extras/bobs_basic_firestarter.sh

Exit chroot:
    exit

The firewall will now be present in /etc/nftables.conf and enabled at boot via /etc/rc.d/rc.firewall.

### Step 4: Installation Finalization

From live environment as root (before reboot):
    sudo /extras/prep_disk.sh /dev/sda

This verifies all components, generates/repairs the initrd when needed,
merges configuration files, and creates read-only initial snapshots of
@ and @home.

The direct UEFI boot entry is created and verified by finalization; no
bootloader configuration is needed before rebooting.

### Step 7: AI Workspace Setup

After first boot, logged in as regular user:
    /extras/mr.clever.pl --profile=agent

Available profiles:
| Profile | Includes |
|---------|----------|
| minimal | Git + tmux + CLI tools |
| agent (default) | minimal + Python/uv + Node/nvm + AI clients |
| full | agent + rootless Podman support |

---

## Requirements

| Requirement | Details |
|-------------|---------|
| OS | Slackware-current or Slackware 16.x |
| Architecture | x86_64, aarch64 |
| Privileges | Root for Steps 1, 3, 4; Regular user for Step 7 |
| Internet | Required for Step 7 (tool downloads) |
| Interpreters | Bash (Steps 1-4), Perl (Step 7) |

---

## Implementation Notes

### Language Choices

| Script | Language | Rationale |
|--------|----------|-----------|
| `prep_disk.sh` | Bash | Live ISO compatibility—guaranteed availability |
| `bobs_basic_firestarter.sh` | Bash | Live ISO compatibility—guaranteed availability |
| `mr.clever.pl` | Perl | Post-install—Perl reliably present in installed system |

---

## Future Roadmap

### Planned Enhancements for prep_disk.sh (v5+)

| Feature | Current | Planned (v5+) |
|---------|---------|---------------|
| Filesystem choice | Btrfs only | ext4, XFS, Btrfs, fscrypt |
| Full disk encryption | Mandatory | Optional (FDE on/off) |
| Swap partition | None | Optional (swap file/partition) |
| Partition sizes | Fixed (1GiB ESP) | Configurable sizes |
| Multiple volumes | Single disk only | RAID/LVM support |

Example future usage:
    sudo /extras/prep_disk.sh /dev/sda --filesystem ext4 --fde off
    sudo /extras/prep_disk.sh /dev/sda --filesystem btrfs --fde on --swap 8G

### Planned Wrapper Script (New in v5+)

A convenience wrapper that orchestrates the entire workflow:

    /extras/scriptware-install.sh /dev/sda

Workflow automation:
    1. Runs prep_disk.sh (first invocation)
    2. Launches standard Slackware setup interactively
    3. Chroots and runs bobs_basic_firestarter.sh
    4. Runs prep_disk.sh (second invocation)
    5. Creates/verifies the direct UEFI boot entry (no bootloader)
    6. Exits with summary

Benefits:
    - Reduces manual step count from 7 to 1 command
    - Maintains all safety checks and confirmations
    - Optional for power users; convenient for repeat deployments
    - Can be extended with additional post-install hooks

Example wrapper:
    #!/bin/bash
    set -e
    DEVICE="$1"
    /extras/prep_disk.sh "$DEVICE"
    setup
    chroot /mnt /extras/bobs_basic_firestarter.sh
    /extras/prep_disk.sh "$DEVICE"
    echo "Now reboot; the direct UEFI entry is already configured."

### Long-Term Vision (v6+)

| Goal | Rationale |
|------|-----------|
| GUI frontend option | Point-and-click installer for less terminal-experienced users |
| Profile presets | Common configurations (desktop, server, laptop, NAS) |
| Network installation | Pull packages over network instead of DVD |
| Clone-friendly | Support for imaging identical systems at scale |
| Backup integration | Automated backup hooks via Btrfs snapshots |
| Rollback support | Easy rollback to initial snapshot after bad updates |

---

## Design Principles

1. Optional by default — Standard Slackware installation works without Scriptware
2. Augmentative only — Extends, never replaces official installer
3. No modification of official packages — Slackware packages stay pristine
4. User-space isolation — Developer tools live in ~/.local, ~/.nvm
5. Safety first — Dry-runs, confirmations, timestamped backups
6. No systemd — Traditional init/service architecture throughout
7. Git as boundary — Changes reviewed through Git before acceptance
8. Backward compatible — Future versions honor existing prep_disk.sh metadata format
9. Live-environment compatible — Pre-install scripts work without Perl

---

## License

MIT License - Copyright (c) 2026 Epoch

See LICENSE file for full terms.

---

## Contributing

Contributions welcome. Please review existing code patterns before submitting patches.

1. Fork the repository
2. Create a feature branch
3. Ensure scripts maintain idempotency where applicable
4. Submit pull request with description
5. Follow Slackware coding conventions (shell for pre-install, Perl/post-install acceptable)
6. Verify pre-install scripts work in actual Slackware live environment (bash only)

---

## Support

Issues and feature requests tracked via GitHub Issues.

For Slackware-specific questions, refer to:
- Official documentation: https://www.slackware.com
- Slackware mailing lists: https://lists.slackware.com
- Slackware forums: https://www.linuxquestions.org/questions/slackware-14/

---

---

## Troubleshooting

### Firestarter Fails in chroot

Ensure `nftables` package is installed in the target system before running `bobs_basic_firestarter.sh`:

    chroot /mnt
    installpkg /path/to/nftables-*-x86_64-*.tgz

Then run the firewall script.

### Prep Disk Won't Execute

If you receive "permission denied" when running `prep_disk.sh`:

    chmod +x /extras/prep_disk.sh
    sudo /extras/prep_disk.sh /dev/sda

### LUKS Container Won't Open

During finalization, if LUKS won't open:
- Verify you're entering the correct password
- Ensure the partition hasn't been wiped/reformatted
- Check `/dev/mapper/lukssda2` doesn't already exist with wrong device

### Snapshots Not Created

If initial Btrfs snapshots weren't created during Step 4:
- Re-run finalization with `sudo /extras/prep_disk.sh /dev/sda`
- Verify Btrfs subvolumes exist with `btrfs subvolume list /mnt`
- Check logs for permission or mount issues

### Dry Run Shows Conflicts But Real Run Fails

If `--dry-run` passes but actual execution fails partway:
- The device may have been modified between dry-run and execution
- Unmount all partitions on the target disk first
- Check for mounted swap or LVM volumes that interfere

### Initrd Generation Fails During Finalization

Common causes:
- `mkinitrd` not installed in the target (`/mnt/sbin/mkinitrd`)
- Kernel modules missing (ensure the kernel package is installed)
- `/proc`, `/sys`, `/dev` could not be bind-mounted into the target

Verify:
    ls -la /mnt/sbin/mkinitrd
    ls -la /mnt/lib/modules/
    ls -la /mnt/boot/vmlinuz-*

Finalization runs mkinitrd with explicit `-r`, `-C`, `-f` and `-m` flags,
then verifies rootdev, luksdev and rootfs before continuing.

### Firmware Doesn't Boot the Direct Kernel

- Verify the entry exists: `efibootmgr -v`
- Verify `BootOrder` starts with the Slackware entry
- Verify the ESP contains `EFI/Slackware/vmlinuz-*` and `initrd-*.img`
- The kernel must be a PE/COFF EFI-stub image
- Secure Boot must be disabled, or the kernel signed
- Confirm the firmware is in UEFI mode, not legacy BIOS

### System Boots But Network Fails

The default firewall blocks unsolicited inbound traffic, which is expected. However:
- Outbound should work normally
- Incoming SSH/DNS requires manual rule additions
- If outbound also fails, check DHCP worked in installation

To allow SSH after boot, edit `/etc/nftables.conf` and add:
    tcp dport 22 ct state new accept

### AI Bootstrap Cannot Connect to GitHub

If `mr.clever.pl` fails downloading tools:
- Test connectivity: `curl -I https://github.com`
- Corporate proxies may require `HTTPS_PROXY` environment variable
- GitHub API rate limits apply; wait a few minutes between retries

### Perl Module Errors in mr.clever.pl

On minimal Slackware installs, some Perl modules may be missing:
- Ensure `perl` package installed in addition to base system
- For JSON handling: `sudo slackpkg install json-perl`
- Alternatively, install dependencies via `cpanm` in user space

### Btrfs Filesystem Corruption Warnings

After unexpected power loss or forced shutdown:
- Boot from live media
- Run: `btrfs check --repair /dev/mapper/lukssda2`
- Then run: `btrfs scrub start /mnt`

Prevention:
- Always use `sync` before powering off
- Enable read-only snapshots for root (automated by Scriptware)

### Disk Space Low on Root Subvolume

Btrfs root (`@`) and home (`@home`) are separate subvolumes:
- Check individual usage: `btrfs filesystem usage /mnt`
- Old snapshots accumulate; prune with `btrfs subvolume delete /path/to/snapshot`
- Consider automated cleanup via cron job

### Dual-Boot Windows Interferes

Windows Fast Startup can lock EFI partition:
- Disable Fast Startup in Windows: Power Options > Choose power button actions > Change unavailable settings > Uncheck "Turn on fast startup"
- Windows hibernation prevents Linux from mounting ESP cleanly

### EFI Boot Entry Missing After First Reboot

Scriptware creates a direct UEFI kernel entry during finalization; it does not
install a traditional bootloader.  Check that finalization completed without
error and that the firmware entry exists:

    efibootmgr -v | grep -i 'Slackware direct'
    ls -l /boot/efi/EFI/Slackware/

If the entry is missing, re-run finalization and review its output.  Do not
add GRUB/ELILO merely because the entry is missing; fix the direct entry.

### nftables Rules Lost After Reboot

The rc.firewall script should load automatically:
- Check `/etc/rc.d/rc.firewall` is executable: `ls -la /etc/rc.d/rc.firewall`
- If not: `chmod +x /etc/rc.d/rc.firewall`
- Test manually: `nft -f /etc/nftables.conf`

### Swap Needed Despite Design Choice

To add swap post-install:
- Create swap file: `dd if=/dev/zero of=/swapfile bs=1M count=8192`
- Secure it: `chmod 600 /swapfile`
- Format it: `mkswap /swapfile`
- Enable it: `swapon /swapfile`
- Persist in fstab: `echo '/swapfile none swap defaults 0 0' >> /etc/fstab`

### Multiple Disks in System

`prep_disk.sh` targets a single disk. If multiple disks present:
- Be explicit with device path: `/dev/sda` vs `/dev/sdb`
- Verify with `lsblk` before running
- Second disk remains untouched but won't be auto-mounted

### USB Drive Detection Issues

USB drives appear as `/dev/sdX` sometimes unpredictably:
- Use persistent naming: `/dev/disk/by-id/usb-*`
- Or use `lsblk` immediately before execution to identify device

### Timeout During LUKS Password Entry

Interactive password prompt may timeout if:
- Running script remotely via SSH without PTY allocation
- Solution: Use `script` command to allocate pseudo-tty: `script -q -c './prep_disk.sh /dev/sda' /dev/null`

### Script Terminates Mid-Execution

If interrupted after disk erasure but before completion:
- Disk is unusable until re-prepared
- Re-run: `sudo /extras/prep_disk.sh /dev/sda`
- All data is lost; script does not support resume

### Mount Points Already Occupied

Error: "mount point already occupied"
- Unmount conflicting targets: `umount /mnt /mnt/home /mnt/boot/efi`
- Or reboot from live media to ensure clean state

### Btrfs Checksum Algorithm Mismatch

If you get checksum errors:
- Original prep_disk uses xxhash64 (fast, slightly less safe than crc32c)
- The `--checksum` option is planned but not implemented; changing it
  requires recreating the filesystem manually with `mkfs.btrfs -c`

### geninitrd Generator Wrong Version (manual use)

The helper does not use geninitrd; it invokes mkinitrd directly with
explicit `-r`, `-C`, `-f` and `-m` flags. If you run geninitrd yourself,
still ensure `/etc/default/geninitrd` sets `GENERATOR=mkinitrd`:
- Check `/etc/default/geninitrd` for `GENERATOR=` setting
- If set to `dracut` or other, change to `mkinitrd`
- Or reinstall geninitrd from Slackware packages

### IPv6 Neighbor Discovery Blocked

Firestarter allows required ND traffic, but if issues arise:
- Check rules: `nft list ruleset`
- Verify: `icmpv6 type {nd-router-advert,nd-neighbor-solicit,nd-neighbor-advert} accept` exists
- Temporary test: disable firewall `nft flush ruleset` then re-enable

### Podman Rootless Mode Fails in Full Profile

If `mr.clever.pl` reports Podman rootless failure:
- Ensure user UID > 0 (not root)
- Check `/etc/subuid` and `/etc/subgid` for UID ranges
- On fresh installs: `sudo usermod --add-subuids 100000-165535 $USER`

### Git Hooks Conflict With AI Tools

AI-generated changes may trigger pre-commit hooks:
- Review `.git/hooks/` in your projects
- Temporarily disable with: `git config core.hooksPath /dev/null`
- Better: make hooks aware of agent changes with comments

### tmux Configuration Overwritten

`.tmux.conf` gets replaced by mr.clever.pl:
- Backup existing config first: `cp ~/.tmux.conf ~/.tmux.conf.backup`
- Merge manually instead of allowing overwrite

### Aliases Clash With Existing Commands

Bootstrap adds aliases that may override existing:
- Review added sections in `~/.bashrc` marked `SLACK_AI_BOOTSTRAP_*`
- Comment out unwanted sections
- Reload shell: `exec bash`

### Profile Selection Incorrect

If wrong profile installed:
- Minimal: no Python/Node/AI tools
- Agent: includes AI clients, no containers
- Full: includes rootless Podman

Re-run with explicit flag:
    /extras/mr.clever.pl --profile=full --non-interactive

### uv or nvm Installation Fails

External script failures:
- uv: `curl -LsSf https://astral.sh/uv/install.sh` may be down
- nvm: GitHub raw CDN blocked by some networks
- Workaround: Download scripts locally, inspect, run manually

### Python Virtual Environment Conflicts

AI tools may conflict with system Python:
- Script uses `uv tool install` to isolate packages
- Avoid mixing with `pip install --user`
- If conflict occurs: `uv tool uninstall <package>` then reinstall

### Node Version Incompatible With AI Clients

AI CLIs may require specific Node versions:
- Check client requirements before installing
- nvm supports multiple versions: `nvm install 20 && nvm use 20`
- Set default: `nvm alias default 'lts/*'`

### Workspace Directories Already Exist

If `$HOME/bin`, `$HOME/ai`, etc. exist:
- Script keeps existing directories unchanged
- New files written inside them are non-destructive
- Existing configs in `~/.bashrc`, `~/.tmux.conf` preserved via append

### Duplicate Entries in .bashrc

Running bootstrap multiple times:
- Script uses markers to prevent duplicate appends
- If duplicates occur, manually remove duplicate `SLACK_AI_BOOTSTRAP_*` sections
- Backup first: `cp ~/.bashrc ~/.bashrc.backup-before-fix`

### Git User Config Already Set

If `git config --global user.name` already configured:
- Script detects this and skips prompting
- To force reconfigure: `git config --global --unset user.name`

### Package Manager (slackpkg) Issues

If native packages fail to install:
- Update mirrors: `sudo slackpkg update`
- Check `/etc/slackpkg/mirrors` for active mirror
- Verify network: `ping mirrors.slackware.com`

### Build Tools Missing For Compilation

Some tools compile from source:
- Ensure `gcc`, `make`, `cmake`, `ninja` available
- Install: `sudo slackpkg install gcc make cmake ninja`

### jq Required But Not Found

GitHub release parsing requires `jq`:
- Install: `sudo slackpkg install jq`
- Without jq, script cannot extract asset URLs from release JSON

### rsync Not Available For File Syncing

Script uses rsync for certain operations:
- Install: `sudo slackpkg install rsync`
- Alternative: Falls back to cp/mv where available

### ssh/openSSH Key Generation

If SSH keys needed for Git authentication:
- Generate: `ssh-keygen -t ed25519 -C "your_email@example.com"`
- Copy public key to service: `cat ~/.ssh/id_ed25519.pub | pbcopy` (or equivalent)

### Firewall Too Restrictive For Services

If hosting services on your machine:
- Edit `/etc/nftables.conf` carefully
- Add inbound rules for specific ports
- Keep `policy drop` on INPUT, add explicit `accept` rules
- Example: Allow HTTP: `tcp dport 80 ct state new accept`

### Testing Changes Safely

Before applying firewall or disk changes:
- Use `--dry-run` flag on prep_disk.sh
- Validate nftables syntax: `nft -c -f /etc/nftables.conf`
- Backup important data regardless of precautions
- Have live USB ready for recovery

### Recovery From Failed Installation

If installation fails midway:
1. Boot from Slackware live media
2. Mount ESP: `mount /dev/sda1 /mnt/boot/efi`
3. Mount LUKS (enter password): `cryptsetup open /dev/sda2 lukssda2`
4. Mount Btrfs: `mount -o subvol=@ /dev/mapper/lukssda2 /mnt`
5. Inspect: `ls -la /mnt/etc/fstab`
6. Fix manually or re-run Scriptware steps

### System Updates Break Compatibility

Major Slackware-current updates may affect:
- geninitrd behavior
- nftables syntax
- Btrfs utilities
- Test updates in VM before deploying to production
- Check Slackware changelog after major package updates

### Security Audit Recommendations

For hardened deployments beyond baseline:

| Recommendation | Purpose | Implementation Effort |
|----------------|---------|----------------------|
| Add fail2ban for SSH protection | Rate-limit brute-force attempts | Medium (package + config) |
| Configure auditd for login monitoring | Track authentication events | Low (enable + basic rules) |
| Enable secure boot with custom keys | Prevent unsigned bootloader execution | High (key generation + enrollment) |
| Use TPM 2.0 for LUKS key binding | Hardware-backed disk encryption | Medium-High (tpm2-tools + crypttab) |
| Regular `btrfs scrub` to detect silent corruption | Data integrity verification | Low (cron job) |

Additional considerations:

- **AppArmor/SELinux**: Slackware doesn't enable by default; optional for MAC policy enforcement
- **Network intrusion detection**: Consider Snort/Suricata for high-risk environments
- **Log aggregation**: Centralize `/var/log` to remote syslog server
- **Encrypted home directories**: FSCrypt or separate encrypted partition for sensitive data
- **Memory sanitizers**: ASan/TSan for development workloads (compile-time, not runtime)
- **Container hardening**: Podman with seccomp profiles if using full profile

### Final Notes

Scriptware provides a solid foundation for modern Slackware installations while respecting the distribution's minimalist philosophy. The tools are designed to be:

- **Understandable**: Read the code before executing
- **Reversible**: Backups are created; snapshots allow rollback
- **Non-intrusive**: Slackware packages remain untouched
- **Extensible**: Future versions maintain backward compatibility

If you encounter issues not covered in this documentation:
1. Review the script source for detailed comments
2. Check Slackware community channels for platform-specific guidance
3. File a GitHub issue with error output and system details

Enjoy your enhanced Slackware installation.

---

## Changelog (Unreleased)

### Current State (v4.3-bash)

| Component | Status | Notes |
|-----------|--------|-------|
| prep_disk.sh | ✅ Bash ported | Live ISO compatible |
| bobs_basic_firestarter.sh | ✅ Bash ported | Live ISO compatible |
| mr.clever.pl | ✅ Perl | Post-install only |
| Documentation | ✅ Updated | Reflects current reality |
| Wrapper script | 🚧 Planned | v5.0 target |
| GUI frontend | 🚧 Future | v6.0 target |

### Known Limitations

1. **Single-disk only**: RAID/LVM support pending
2. **Btrfs-only filesystem**: ext4/XFS options pending
3. **No automatic swap**: Administrator must add if needed
4. **Internet-dependent bootstrap**: Offline deployment requires manual tool fetching
5. **Firewall baseline minimal**: Application-specific rules require manual configuration

---

## Quick Reference Cards

### Pre-Installation Checklist

- [ ] Verified target disk with `lsblk`
- [ ] Backed up any existing data
- [ ] Prepared Slackware installation media
- [ ] Located Scriptware scripts in `/extras`
- [ ] Read all warning notices
- [ ] Understood LUKS password cannot be recovered if lost

### Post-Installation Checklist

- [ ] Booted successfully into new system
- [ ] Decrypted disk correctly at boot prompt
- [ ] Firewall active: `nft list ruleset` shows rules
- [ ] Git configured: `git config user.name`
- [ ] AI tools accessible: `codex --version` or similar
- [ ] Snapshots created: `btrfs subvolume list /`

### Emergency Recovery Commands

```bash
# Boot from live media, unlock disk, mount
cryptsetup open /dev/sda2 lukssda2
mount -o subvol=@ /dev/mapper/lukssda2 /mnt
mount /dev/sda1 /mnt/boot/efi
chroot /mnt

# Restore firewall if broken
/etc/rc.d/rc.firewall start
nft -f /etc/nftables.conf

# Regenerate initrd if boot fails: re-run finalization from live media
# /extras/prep_disk-7.1.sh /dev/sda
# (or run mkinitrd directly with explicit -r/-C/-f/-m flags)

# Fix fstab if mount issues
cat /etc/fstab | grep -v prep_disk.sh > /tmp/fstab.clean
mv /tmp/fstab.clean /etc/fstab

# Exit and reboot
exit
umount -R /mnt
cryptsetup close lukssda2
reboot
```

## External Resources

### Official Slackware

| Resource | URL |
|----------|-----|
| Homepage | https://www.slackware.com |
| Documentation | http://www.slackbook.org |
| Mailing Lists | https://lists.slackware.com |
| Current Announcements | ftp://ftp.slackware.com/pub/slackware/current/ |

### Community

| Resource | Description |
|----------|-------------|
| LinuxQuestions.org | Slackware forum (https://www.linuxquestions.org/questions/slackware-14/) |
| r/Slackware | Reddit community |
| Slackware IRC | irc.libera.chat #slackware |
| Arch Wiki | Useful for concepts even on Slackware |

### Security Tools

| Tool | Purpose | Package Name |
|------|---------|--------------|
| nftables | Packet filtering | nftables |
| fail2ban | Intrusion prevention | fail2ban |
| auditd | System auditing | audit |
| tpm2-tools | TPM 2.0 management | tpm2-tools |
| btrfs-progs | Btrfs utilities | btrfs-progs |

---

## Credits

**Original Design**: Epoch (2026)

**Bash Porting**: Community contribution addressing live environment constraints

**Contributors**: See GitHub contributors for detailed attribution

Special thanks to the Slackware community for maintaining the tradition of simplicity, control, and respect for the administrator's expertise.

---

*Last updated: 2026-09-27*
