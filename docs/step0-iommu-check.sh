#!/bin/bash
#
# ebb :: Step 0 — IOMMU / VT-d preflight
#
# RUN THIS ON THE EXISTING UBUNTU INSTALL.
#
# Not in dom0 (that is qubes/verify.sh), not on the KVM host as a hardening
# step (that is kvm/ansible/playbook.yml), and above all not inside a VM —
# see the virtualisation guard below.
#
# Read-only. It reads sysfs, /proc and the kernel log. It changes nothing,
# and it needs no privilege except to read the kernel log on a distro that
# restricts it (Ubuntu does).
#
#     bash docs/step0-iommu-check.sh
#     sudo bash docs/step0-iommu-check.sh     # if the log read comes back empty
#
# WHY THIS EXISTS RATHER THAN THREE GREPS:
#   The hand-run version of this check cannot tell the difference between
#   "the firmware does not expose VT-d" and "you lack permission to read
#   dmesg". Both print nothing. One of those answers means abandoning Engine
#   A; the other means typing sudo. A check whose negative result has five
#   possible causes is not a decision input, and this step is the step the
#   whole project's direction hangs on.
#
# Exit codes:
#   0  Engine A not ruled out — proceed to Step 1/2. NOT a confirmation.
#   1  script or usage error
#   2  Engine A ruled out on this machine — Engine B is the near-term path
#   3  indeterminate — could not read what it needed; re-run with sudo

set -o errexit
set -o nounset
set -o pipefail

readonly ACPI_TABLES=/sys/firmware/acpi/tables

# Populated by read_kernel_log().
KERNEL_LOG=""
KERNEL_LOG_SRC=""

# Verdict accumulators. Each fact sets exactly one of these.
fw_table=unknown        # yes | no
kernel_iommu=unknown    # yes | no
intremap=unknown        # yes | no | indeterminate
virt_ext=unknown        # yes | no
vendor=unknown          # intel | amd | other

pass()    { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail()    { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
warn()    { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
info()    { printf '  \033[36mINFO\033[0m  %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------------------
# Guard: are we even on the right machine?
# --------------------------------------------------------------------------
#
# A hypervisor presents an emulated platform. Inside a VM this script will
# usually find no DMAR table and no IOMMU and report "Engine A ruled out" —
# a conclusion about the hypervisor, not about the hardware you are deciding
# the fate of. This is the single easiest way to get a confidently wrong
# answer out of Step 0, so it aborts rather than guessing.

check_not_virtualised() {
    section "Running on real hardware?"

    local virt="none"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt 2>/dev/null || echo none)"
    elif command -v hostnamectl >/dev/null 2>&1; then
        virt="$(hostnamectl 2>/dev/null | awk -F': ' '/Virtualization/ {print $2}')"
        virt="${virt:-none}"
    else
        warn "cannot detect virtualisation (no systemd-detect-virt)"
        info "if this is a VM or container, STOP — the verdict will be about"
        info "the hypervisor's emulated platform, not your laptop"
        return 0
    fi

    if [[ "$virt" == "none" ]]; then
        pass "bare metal"
        return 0
    fi

    fail "running under virtualisation: ${virt}"
    printf '\n'
    printf 'Step 0 is a question about physical firmware and physical silicon.\n'
    printf 'Asked inside a %s guest it answers for the emulated platform.\n' "$virt"
    printf 'Boot the Ubuntu install on the metal and run it there.\n\n'
    exit 3
}

# --------------------------------------------------------------------------
# CPU vendor — decides which ACPI table and which log prefix to look for
# --------------------------------------------------------------------------
#
# Intel publishes DMAR and logs under "DMAR:" / "DMAR-IR:". AMD publishes
# IVRS and logs under "AMD-Vi:". Looking for the Intel spelling on an AMD box
# returns nothing and reads as "no IOMMU", which is the same false negative
# this script exists to prevent.

detect_vendor() {
    section "CPU"

    local model vendor_id
    model="$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    vendor_id="$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"

    info "${model:-unknown model}"

    case "$vendor_id" in
        GenuineIntel) vendor=intel; info "vendor: Intel — expecting DMAR / VT-d" ;;
        AuthenticAMD) vendor=amd;   info "vendor: AMD — expecting IVRS / AMD-Vi" ;;
        *)            vendor=other; warn "unrecognised vendor '${vendor_id}'" ;;
    esac
}

# --------------------------------------------------------------------------
# Fact 1 — did the FIRMWARE publish an IOMMU description table?
# --------------------------------------------------------------------------
#
# This is the one that means "VT-d is enabled in the BIOS". It is the only
# fact here that no kernel parameter can change: if the firmware does not
# describe an IOMMU, Linux cannot invent one, Xen cannot invent one, and
# Engine A's containment claim is finished on this machine.
#
# Note the table node is mode 0400, so the listing needs root; its EXISTENCE
# is readable either way, which is all we need.

check_firmware_table() {
    section "Fact 1 — firmware IOMMU table (is VT-d on in the BIOS?)"

    local want
    case "$vendor" in
        intel) want=DMAR ;;
        amd)   want=IVRS ;;
        *)     want="" ;;
    esac

    if [[ -z "$want" ]]; then
        warn "unknown vendor; checking for either DMAR or IVRS"
        if [[ -e "${ACPI_TABLES}/DMAR" || -e "${ACPI_TABLES}/IVRS" ]]; then
            fw_table=yes; pass "an IOMMU table is present"
        else
            fw_table=no;  fail "neither DMAR nor IVRS present"
        fi
        return 0
    fi

    if [[ ! -d "$ACPI_TABLES" ]]; then
        warn "${ACPI_TABLES} does not exist — cannot read firmware tables"
        fw_table=unknown
        return 0
    fi

    if [[ -e "${ACPI_TABLES}/${want}" ]]; then
        fw_table=yes
        pass "${want} table present — firmware describes an IOMMU"
    else
        fw_table=no
        fail "${want} table ABSENT — firmware does not describe an IOMMU"
        info "this is a BIOS fact, not a Linux fact; no kernel flag fixes it"
    fi
}

# --------------------------------------------------------------------------
# Fact 2 — did the KERNEL bind an IOMMU, and group devices behind it?
# --------------------------------------------------------------------------
#
# /sys/class/iommu populated means a driver attached. iommu_groups populated
# means devices were actually partitioned into DMA domains, which is the
# property you care about rather than merely "a driver loaded".

check_kernel_iommu() {
    section "Fact 2 — kernel bound an IOMMU"

    local units=0 groups=0

    if [[ -d /sys/class/iommu ]]; then
        units="$(find /sys/class/iommu -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    fi
    if [[ -d /sys/kernel/iommu_groups ]]; then
        groups="$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    fi

    if (( units > 0 )); then
        kernel_iommu=yes
        pass "/sys/class/iommu: ${units} unit(s) — $(ls /sys/class/iommu 2>/dev/null | tr '\n' ' ')"
    else
        kernel_iommu=no
        fail "/sys/class/iommu is empty — no IOMMU driver bound"
    fi

    if (( groups > 0 )); then
        pass "/sys/kernel/iommu_groups: ${groups} group(s) — devices are partitioned"
    else
        fail "/sys/kernel/iommu_groups is empty — no device is behind an IOMMU"
    fi

    # If the firmware table is there but the kernel did not use it, the fix is
    # a boot flag, not a new laptop. Say so, and say how to check which it is.
    if [[ "$fw_table" == "yes" && "$kernel_iommu" == "no" ]]; then
        warn "firmware describes an IOMMU but the kernel did not enable it"
        local cfg="/boot/config-$(uname -r)"
        if [[ -r "$cfg" ]]; then
            local dflt
            dflt="$(grep -E '^CONFIG_(INTEL|AMD)_IOMMU_DEFAULT_ON' "$cfg" 2>/dev/null || true)"
            info "${dflt:-CONFIG_*_IOMMU_DEFAULT_ON not set in ${cfg}}"
        fi
        info "recoverable: add intel_iommu=on to the kernel cmdline, reboot, re-run"
        info "current cmdline: $(cat /proc/cmdline)"
    fi
}

# --------------------------------------------------------------------------
# Kernel log acquisition
# --------------------------------------------------------------------------
#
# Try journalctl -k first, for two reasons: it is readable by members of adm /
# systemd-journal without root (Ubuntu puts the first user in adm), and it is
# not a fixed-size ring. The dmesg buffer can and does evict early-boot DMAR
# lines on a desktop that has been up for days with a chatty driver, which
# produces an empty grep on a machine whose IOMMU is working.

read_kernel_log() {
    local out=""

    out="$(journalctl -k -b --no-pager 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
        KERNEL_LOG="$out"; KERNEL_LOG_SRC="journalctl -k -b"
        return 0
    fi

    out="$(dmesg 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
        KERNEL_LOG="$out"; KERNEL_LOG_SRC="dmesg"
        return 0
    fi

    return 1
}

# --------------------------------------------------------------------------
# Fact 3 — interrupt remapping, and what the kernel actually said
# --------------------------------------------------------------------------
#
# WHY INTERRUPT REMAPPING IS A GATE AND NOT A DETAIL:
#   Xen refuses to enable VT-d at all when interrupt remapping is
#   unavailable, unless booted with iommu=no-intremap. Without it a device
#   behind the IOMMU is still DMA-constrained but can inject interrupts it
#   was never assigned — an escape from the driver domain, which is the exact
#   property sys-net and sys-usb exist to provide. "IOMMU yes, intremap no"
#   is therefore not a partial win; for this project it is the same answer as
#   no IOMMU, arrived at after buying an enclosure. Free to check here.

check_kernel_log() {
    section "Fact 3 — what the kernel said (incl. interrupt remapping)"

    if ! read_kernel_log; then
        intremap=indeterminate
        warn "kernel log unreadable — this is NOT a negative result"
        if [[ "$(id -u)" != "0" ]]; then
            info "Ubuntu ships kernel.dmesg_restrict=1. Re-run: sudo bash $0"
        else
            info "even as root the log came back empty; check journald storage"
        fi
        return 0
    fi

    info "log source: ${KERNEL_LOG_SRC}"

    local prefix success_line
    case "$vendor" in
        amd) prefix='AMD-Vi' ; success_line='AMD-Vi' ;;
        *)   prefix='DMAR'   ; success_line='Virtualization Technology for Directed I/O' ;;
    esac

    local hits
    hits="$(printf '%s\n' "$KERNEL_LOG" | grep -i -e "$prefix" -e IOMMU || true)"

    if [[ -z "$hits" ]]; then
        fail "no ${prefix}/IOMMU lines in the kernel log at all"
        intremap=no
        return 0
    fi

    # The "it came up" line. For Intel this is emitted at the tail of a
    # successful intel_iommu_init(). Deliberately NOT grepping for
    # "DMAR: IOMMU enabled": the kernel prints that from its command-line
    # PARSER, only when intel_iommu=on was passed explicitly. With the IOMMU
    # on by default that string is absent on a perfectly working machine, and
    # reading its absence as "no IOMMU" is the most expensive mistake
    # available at this step.
    if printf '%s\n' "$hits" | grep -qi "$success_line"; then
        pass "IOMMU initialised: $(printf '%s\n' "$hits" | grep -i "$success_line" | head -1 | sed 's/^.*\] //')"
    else
        warn "did not see the init-succeeded line (${success_line})"
    fi

    if printf '%s\n' "$hits" | grep -qi -e 'DMAR-IR.*Enabled IRQ remapping' -e 'Interrupt remapping enabled'; then
        intremap=yes
        pass "interrupt remapping ENABLED: $(printf '%s\n' "$hits" | grep -i 'Enabled IRQ remapping' | head -1 | sed 's/^.*\] //')"
    elif printf '%s\n' "$hits" | grep -qi 'DMAR-IR'; then
        intremap=no
        fail "DMAR-IR lines present but remapping not reported enabled:"
        printf '%s\n' "$hits" | grep -i 'DMAR-IR' | sed 's/^/        /'
    else
        intremap=no
        fail "no interrupt-remapping lines — Xen will refuse VT-d without"
        fail "iommu=no-intremap, which voids the containment property"
    fi

    # RMRR regions are informational but predictive: Xen must identity-map
    # them for passthrough, and conflicts here are a documented cause of
    # sys-usb failing to start on laptops. Worth recording now, while the
    # log is already open.
    local rmrr
    rmrr="$(printf '%s\n' "$hits" | grep -ci 'RMRR' || true)"
    if (( rmrr > 0 )); then
        info "${rmrr} RMRR line(s) — reserved regions Xen must identity-map:"
        printf '%s\n' "$hits" | grep -i 'RMRR' | sed 's/^.*\] /        /'
        info "RMRR conflicts are a known cause of sys-usb failing under Xen"
    fi

    printf '\n'
    info "full ${prefix}/IOMMU log follows"
    printf '%s\n' "$hits" | sed 's/^/        /'
}

# --------------------------------------------------------------------------
# Fact 4 — hardware virtualisation extensions
# --------------------------------------------------------------------------
#
# Checked HERE, at Step 0, rather than in Step 2's qubes-hcl-report, because
# it is the same BIOS trip and it gates BOTH engines: Engine A needs VT-x for
# Xen HVM, Engine B needs it for KVM. If this is off, "fall back to Engine B"
# is not a fallback — there is nothing to fall back to until you fix the BIOS.

check_virt_ext() {
    section "Fact 4 — VT-x / AMD-V (gates Engine A AND Engine B)"

    if grep -qw -e vmx -e svm /proc/cpuinfo 2>/dev/null; then
        virt_ext=yes
        pass "hardware virtualisation present in /proc/cpuinfo"
    else
        virt_ext=no
        fail "no vmx/svm flag — virtualisation is DISABLED IN FIRMWARE"
        info "this blocks Qubes AND KVM; fix in BIOS before anything else"
    fi
}

# --------------------------------------------------------------------------
# Verdict
# --------------------------------------------------------------------------
#
# WHAT THIS STEP CAN AND CANNOT PROVE:
#   It can RULE OUT Engine A. No firmware table means no IOMMU means sys-net
#   and sys-usb are not containment, and no Qubes configuration changes that.
#   It cannot CONFIRM Engine A. Xen does its own DMAR parsing and carries its
#   own quirk list; it can and does disable VT-d on hardware Linux is happy
#   with. The authoritative test stays Step 2's `xl info | grep virt_caps`,
#   wanting `hvm hvm_directio`. This script is the cheap filter that stops
#   you buying an enclosure for nothing.

verdict() {
    section "Verdict"

    printf '  firmware IOMMU table : %s\n' "$fw_table"
    printf '  kernel bound IOMMU   : %s\n' "$kernel_iommu"
    printf '  interrupt remapping  : %s\n' "$intremap"
    printf '  VT-x / AMD-V         : %s\n' "$virt_ext"
    printf '\n'

    if [[ "$virt_ext" == "no" ]]; then
        printf '  \033[31mBOTH ENGINES BLOCKED\033[0m — no VT-x/AMD-V.\n'
        printf '  Enable virtualisation in the BIOS and re-run. Engine B needs\n'
        printf '  this too, so there is no fallback to take until it is on.\n\n'
        return 2
    fi

    if [[ "$fw_table" == "no" ]]; then
        printf '  \033[31mENGINE A RULED OUT\033[0m on this machine.\n'
        printf '  The firmware does not describe an IOMMU, so VT-d is off or\n'
        printf '  absent in the BIOS. Look for VT-d / "Intel Virtualization\n'
        printf '  Technology for Directed I/O" (ASUS: Advanced Mode, F7).\n'
        printf '  If the toggle is not there, Engine A becomes a homelab-server\n'
        printf '  project and Engine B on this Ubuntu install is the better use\n'
        printf '  of effort.\n\n'
        printf '  BEFORE CHANGING BIOS SETTINGS: have the BitLocker recovery key\n'
        printf '  for the Windows partition to hand. Changing firmware settings\n'
        printf '  alters the TPM measurements BitLocker seals against.\n\n'
        return 2
    fi

    if [[ "$kernel_iommu" == "no" ]]; then
        printf '  \033[33mINDETERMINATE — RECOVERABLE\033[0m\n'
        printf '  Firmware describes an IOMMU; this kernel did not enable it.\n'
        printf '  Add intel_iommu=on to GRUB_CMDLINE_LINUX_DEFAULT, run\n'
        printf '  update-grub, reboot, and re-run this script. Decide nothing\n'
        printf '  until you have — the hardware has not answered yet.\n\n'
        return 3
    fi

    if [[ "$intremap" == "indeterminate" ]]; then
        printf '  \033[33mINDETERMINATE\033[0m — IOMMU is up, but the kernel log\n'
        printf '  could not be read, so interrupt remapping is unverified.\n'
        printf '  Re-run with sudo. Do not record a result from this run.\n\n'
        return 3
    fi

    if [[ "$intremap" == "no" ]]; then
        printf '  \033[31mENGINE A RULED OUT (effectively)\033[0m\n'
        printf '  An IOMMU is present but interrupt remapping is not up. Xen\n'
        printf '  refuses VT-d without it unless booted iommu=no-intremap, and\n'
        printf '  that flag hands back the exact property sys-net and sys-usb\n'
        printf '  exist to provide: a device that can inject interrupts it was\n'
        printf '  never assigned has escaped its driver domain.\n'
        printf '  Check BIOS for an interrupt-remapping or x2APIC setting; if\n'
        printf '  there is none, treat this as "no IOMMU" and take Engine B.\n\n'
        return 2
    fi

    printf '  \033[32mENGINE A NOT RULED OUT\033[0m — proceed to Step 1 / Step 2.\n'
    printf '  This is not a confirmation. Linux having a working IOMMU is\n'
    printf '  necessary but not sufficient evidence for Xen having one. The\n'
    printf '  authoritative test is Step 2, in dom0:\n'
    printf '      xl info | grep virt_caps     # want: hvm hvm_directio\n'
    printf '  Install to the external NVMe first. The internal disk stays\n'
    printf '  untouched until Step 3.\n\n'
    return 0
}

# --------------------------------------------------------------------------

main() {
    printf '\033[1mebb :: Step 0 — IOMMU / VT-d preflight\033[0m\n'
    printf 'Host: %s   Kernel: %s\n' "$(hostname)" "$(uname -r)"

    check_not_virtualised
    detect_vendor
    check_firmware_table
    check_kernel_iommu
    check_kernel_log
    check_virt_ext

    local rc=0
    verdict || rc=$?
    exit "$rc"
}

main "$@"
