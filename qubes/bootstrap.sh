#!/bin/bash
#
# hybrid-paradigm :: Engine A bootstrap
#
# RUN THIS IN dom0.
#
# dom0 has no network and no package manager access to the internet by design.
# Transfer this repo in with:
#     qvm-run --pass-io <vm> 'cat /path/hybrid-paradigm.tar' > hybrid-paradigm.tar
# NEVER with qvm-copy-to-vm in the other direction, and never curl|bash.
#
# This script is deliberately idempotent: every step checks for its own
# completion first, so a failed run can be re-run without damage.

set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_TAG="hybrid-bootstrap"

# Stock Whonix 18 names as shipped in Qubes 4.3. Do not rename these; the
# Whonix core addon (qubes-core-admin-addon-whonix) keys off them for the
# anti-leak enforcement added in 4.3.
readonly WS_TEMPLATE="whonix-workstation-18"
readonly GW_SYS="sys-whonix"

# Our one new object: a DVM base layered on the stock workstation template.
readonly ANON_DVM="anon-dvm"

# Preloaded disposables (4.3 feature). The Whonix core addon requires at least
# 1500MB free memory reserved for this to behave; 2 is sane on 16GB+, drop to
# 1 on 8GB.
readonly PRELOAD_MAX="${PRELOAD_MAX:-2}"

log()  { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
die()  { printf '[%s] FATAL: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# 0. Preconditions
# --------------------------------------------------------------------------

[[ "$(hostname)" == "dom0" ]] || die "must run in dom0"

command -v qvm-prefs >/dev/null  || die "qvm-prefs missing — is this really dom0?"

# Refuse to run on an unsupported release. 4.2 went EOL 2026-06-21.
if ! grep -qE '^R4\.3' /etc/qubes-release 2>/dev/null; then
    log "WARNING: /etc/qubes-release is not R4.3:"
    log "  $(cat /etc/qubes-release 2>/dev/null || echo unknown)"
    log "This config targets 4.3 (Whonix 18, preloaded disposables, new policy"
    log "format). On 4.2 the template names and the preload feature differ."
    read -r -p "Continue anyway? [y/N] " reply
    [[ "$reply" == "y" ]] || exit 1
fi

# --------------------------------------------------------------------------
# 1. Hardware isolation sanity check
# --------------------------------------------------------------------------
#
# Without VT-d, sys-net and sys-usb are not containment — a malicious NIC or
# USB controller can DMA into dom0. The build will still work, but you should
# know what you are and are not getting.

log "checking IOMMU status"
if xl info 2>/dev/null | grep -q 'virt_caps.*hvm_directio'; then
    log "  VT-d (hvm_directio): ACTIVE"
else
    log "  VT-d: NOT ACTIVE"
    log "  Driver-domain isolation is NOT enforced on this machine."
    log "  AppVM separation still works; DMA attacks from PCI devices do not"
    log "  get stopped. Check BIOS for VT-d / 'Intel Virtualization Technology"
    log "  for Directed I/O'."
    read -r -p "Continue without VT-d? [y/N] " reply
    [[ "$reply" == "y" ]] || exit 1
fi

# --------------------------------------------------------------------------
# 2. Whonix presence
# --------------------------------------------------------------------------

if ! qvm-check --quiet "$WS_TEMPLATE" 2>/dev/null; then
    die "$WS_TEMPLATE not installed. Install it first:
    sudo qubes-dom0-update qubes-template-whonix-workstation-18 \\
                           qubes-template-whonix-gateway-18"
fi

qvm-check --quiet "$GW_SYS" 2>/dev/null \
    || die "$GW_SYS does not exist. Run the Whonix setup wizard first."

# --------------------------------------------------------------------------
# 3. Install Salt states and policy
# --------------------------------------------------------------------------

log "installing salt states into /srv/user_salt"
sudo install -d -m 0755 /srv/user_salt
sudo cp -r "${SCRIPT_DIR}/salt/hybrid-anon"      /srv/user_salt/
sudo cp    "${SCRIPT_DIR}/salt/hybrid-anon.top"  /srv/user_salt/

log "enabling top file"
sudo qubesctl top.enable hybrid-anon

log "applying state to dom0"
sudo qubesctl --show-output state.apply

log "installing RPC policy"
sudo install -m 0664 -o root -g qubes \
    "${SCRIPT_DIR}/policy/30-hybrid-anon.policy" \
    /etc/qubes/policy.d/30-hybrid-anon.policy

# --------------------------------------------------------------------------
# 4. Launcher
# --------------------------------------------------------------------------

log "installing anon-disp launcher"
sudo install -m 0755 "${SCRIPT_DIR}/bin/anon-disp" /usr/local/bin/anon-disp

# --------------------------------------------------------------------------
# 5. Preloaded disposables
# --------------------------------------------------------------------------
#
# Preloading keeps N disposables warm in the background so "open in disposable"
# is instant instead of a 15-second cold boot. The Whonix core addon was fixed
# in 4.3.4 specifically so preloaded Whonix-based disposables cannot bypass Tor
# during the warm-up window.

log "setting preload-dispvm-max=${PRELOAD_MAX} on ${ANON_DVM}"
qvm-features "$ANON_DVM" preload-dispvm-max "$PRELOAD_MAX"

log "done. run ./verify.sh to assert the topology."
log ""
log "Bind a hotkey:  Settings -> Keyboard -> Shortcuts -> Custom"
log "  command: /usr/local/bin/anon-disp"
log "  suggested binding: Ctrl+Alt+A"
