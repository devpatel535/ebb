#!/bin/bash
#
# hybrid-paradigm :: Engine A verification
#
# Asserts the topology rather than assuming it. Run in dom0 after bootstrap.sh
# and after every Qubes or Whonix update — template upgrades have historically
# been where netvm assignments quietly revert.
#
# Exit 0 = all assertions hold. Exit 1 = at least one failed.

set -o nounset
set -o pipefail

readonly DVM="anon-dvm"
readonly GW="sys-whonix"

fails=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '  \033[36mINFO\033[0m  %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------------------
section "Hardware isolation"
# --------------------------------------------------------------------------

if xl info 2>/dev/null | grep -q 'hvm_directio'; then
    pass "VT-d active (hvm_directio in virt_caps)"
else
    fail "VT-d NOT active — sys-net/sys-usb are not real containment"
fi

if xl info 2>/dev/null | grep -q 'virt_caps.*hvm'; then
    pass "VT-x active"
else
    fail "VT-x NOT active"
fi

# --------------------------------------------------------------------------
section "Anonymous compartment topology"
# --------------------------------------------------------------------------

if qvm-check --quiet "$DVM" 2>/dev/null; then
    pass "$DVM exists"
else
    fail "$DVM does not exist"
    printf '\nAborting: nothing else is meaningful without it.\n'
    exit 1
fi

netvm="$(qvm-prefs "$DVM" netvm 2>/dev/null)"
[[ "$netvm" == "$GW" ]] \
    && pass "$DVM netvm = $GW" \
    || fail "$DVM netvm = '$netvm' (expected $GW) — THIS IS A CLEARNET LEAK"

tfd="$(qvm-prefs "$DVM" template_for_dispvms 2>/dev/null)"
[[ "$tfd" == "True" ]] \
    && pass "$DVM template_for_dispvms = True" \
    || fail "$DVM template_for_dispvms = '$tfd'"

vmode="$(qvm-prefs "$DVM" virt_mode 2>/dev/null)"
[[ "$vmode" == "pvh" ]] \
    && pass "$DVM virt_mode = pvh (no emulated device model)" \
    || fail "$DVM virt_mode = '$vmode' — expected pvh; hvm adds a QEMU stubdomain"

tmpl="$(qvm-prefs "$DVM" template 2>/dev/null)"
case "$tmpl" in
    whonix-workstation-*) pass "$DVM template = $tmpl" ;;
    *) fail "$DVM template = '$tmpl' — not a Whonix workstation template" ;;
esac

# --------------------------------------------------------------------------
section "Gateway"
# --------------------------------------------------------------------------

if qvm-check --quiet "$GW" 2>/dev/null; then
    pass "$GW exists"
    gwt="$(qvm-prefs "$GW" template 2>/dev/null)"
    case "$gwt" in
        whonix-gateway-*) pass "$GW template = $gwt" ;;
        *) fail "$GW template = '$gwt' — not a Whonix gateway template" ;;
    esac
    [[ "$(qvm-prefs "$GW" provides_network)" == "True" ]] \
        && pass "$GW provides_network = True" \
        || fail "$GW provides_network is not True"
    info "$GW upstream netvm = $(qvm-prefs "$GW" netvm)  (clearnet side — expected)"
else
    fail "$GW does not exist"
fi

# --------------------------------------------------------------------------
section "Fail-closed behaviour"
# --------------------------------------------------------------------------
#
# Not tested by firing packets — tested structurally, which is stronger.
# A qube cannot reach a network its netvm does not provide. The only question
# that matters is whether any qube in the anon chain has a second path.

info "Qubes provides network as a vif pair from the netvm. If $GW stops,"
info "the interface in each child disappears; there is no fallback route to"
info "the physical NIC because one was never created. No firewall rule is"
info "involved, and none can be, which is why this is structural."

# Confirm no anon-tagged qube has been given a second netvm by hand.
while read -r vm; do
    [[ -z "$vm" ]] && continue
    n="$(qvm-prefs "$vm" netvm 2>/dev/null)"
    if [[ "$n" == "$GW" ]]; then
        pass "$vm -> $GW"
    else
        fail "$vm -> '$n' — off the Tor path"
    fi
done < <(qvm-ls --tags anon --raw-list 2>/dev/null)

# --------------------------------------------------------------------------
section "RPC policy"
# --------------------------------------------------------------------------

readonly POL=/etc/qubes/policy.d/30-hybrid-anon.policy

if [[ -f "$POL" ]]; then
    pass "policy file installed"
    for rule in \
        "qubes.ClipboardPaste.*@dispvm:${DVM}.*vault.*deny" \
        "qubes.Filecopy.*@dispvm:${DVM}.*@anyvm.*deny" \
        "qubes.OpenURL.*@dispvm:${DVM}.*@anyvm.*deny"
    do
        grep -Eq "$rule" "$POL" \
            && pass "rule present: ${rule%%.*} ..." \
            || fail "rule MISSING: $rule"
    done
else
    fail "$POL not installed"
fi

# Ask the policy engine what it would actually do, rather than trusting that
# our file wins the ordering contest against 90-default.policy.
if command -v qubes-policy-lookup >/dev/null 2>&1; then
    head "Policy engine evaluation (authoritative)"
    for target in vault personal work; do
        qvm-check --quiet "$target" 2>/dev/null || continue
        result="$(qubes-policy-lookup qubes.Filecopy "@dispvm:${DVM}" "$target" 2>&1 || true)"
        case "$result" in
            *deny*) pass "Filecopy @dispvm:${DVM} -> ${target}: deny" ;;
            *)      fail "Filecopy @dispvm:${DVM} -> ${target}: ${result}" ;;
        esac
    done
else
    info "qubes-policy-lookup not present; skipped live evaluation"
fi

# --------------------------------------------------------------------------
section "Result"
# --------------------------------------------------------------------------

if (( fails == 0 )); then
    printf '  all assertions hold\n\n'
    exit 0
else
    printf '  %d assertion(s) failed\n\n' "$fails"
    exit 1
fi
