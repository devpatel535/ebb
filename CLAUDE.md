# ebb

`github.com/devpatel535/ebb`

Hardened dual-engine isolation kit. Permanence and compartmentalisation
(GrapheneOS model) with on-demand amnesic, Tor-bound workspaces (Tails model).

- **Engine A** (`qubes/`) — Qubes OS 4.3 + Whonix 18. Hypervisor-enforced.
- **Engine B** (`kvm/`) — hardened Linux host + KVM/libvirt + Whonix KVM.
  Kernel-enforced, weaker, for hardware that can't run Qubes.

---

## Working principles for this repo

**1. The README's "Deviations" section is the spec of record.**
This project was generated from an LLM-written architecture prompt that
contained ten errors — inverted settings, obsolete checks, and one
requirement that is not physically implementable. Each is documented in
`README.md` with the reason it was rejected. **Do not "restore" a dropped
setting because it looks like hardening.** If you think a deviation is wrong,
argue it in a PR against the stated reason; don't silently re-add it.

The standing failure mode here is cargo-cult hardening: flags that look
serious, cost real performance, and buy nothing. Every parameter in this repo
should be defensible out loud. If you add one, add its reason next to it.

**2. Nothing in this repo has been run against real hardware yet.**
It is syntax-checked (`bash -n`, `xmllint`, YAML parse) and written against
Qubes 4.3 / Whonix 18 documented behaviour. It is not integration-tested.
Treat every file as a reviewed draft until `qubes/verify.sh` passes on
metal. Don't describe it as working.

**3. Verify, don't assume.**
`qubes/verify.sh` asserts topology rather than trusting it. When adding a
security property, add the assertion that proves it in the same change.
Netvm assignments have historically reverted across template upgrades.

**4. dom0 hygiene.**
`qubes/bootstrap.sh` runs in dom0, which has no network by design. Never add
a step that curls, pips, or otherwise pulls code into dom0. Transfer in via
`qvm-run --pass-io` only.

---

## Hardware context

Target machine: ASUS VivoBook X1502ZA, i7-1255U (Alder Lake-U), 24GB RAM,
512GB SSD, currently triple-booting Windows / Ubuntu / Kali.

Three open blockers for Engine A on this machine:

1. **VT-d unverified.** `dmesg | grep -i -e DMAR -e IOMMU` on the Ubuntu
   install. ASUS consumer BIOSes frequently don't expose VT-d even when the
   CPU supports it. No IOMMU means sys-net and sys-usb aren't real
   containment.
2. **Alder Lake has thin HCL coverage** — few reports, a meaningful share
   showing problems. Suspend/resume is the usual casualty.
3. **Secure Boot conflict.** Qubes ships Xen, which isn't shim-signed. The
   existing BitLocker/GRUB fix path (re-enable Secure Boot with a
   Microsoft-signed shim) is mutually exclusive with adding Qubes to the
   same boot chain.

Plus: 512GB already split three ways; Qubes wants 150GB+ to be usable.

**Test ladder** — do not skip to step 3:
1. Whonix 18 under VMware on Windows. Tests the anonymity workflow only.
2. **Qubes 4.3 installed to an external NVMe SSD (aluminium enclosure,
   USB 3.2), booted via the F2 boot menu.** Internal disk untouched. This is
   the only real hardware test — Qubes has no live mode, and nesting it under
   a type-2 hypervisor cannot exercise VT-d at all.
3. Internal partition, only if steps 1–2 pass. Note Qubes explicitly
   discourages dual-boot; the external SSD may be the correct permanent home.

---

## Layout

```
docs/TESTING.md             # hardware verification ladder — the lab notebook
qubes/                      # Engine A — runs in dom0
  bootstrap.sh              # idempotent installer
  verify.sh                 # topology assertions; run after every update
  bin/anon-disp             # hotkey launcher, refuses to run if netvm drifted
  policy/30-hybrid-anon.policy
  salt/hybrid-anon{,.top}   # creates exactly one object: anon-dvm
kvm/                        # Engine B — runs on the hardened host
  ansible/playbook.yml
  ansible/files/            # sysctl, libvirt network XML
  ansible/vars.local.yml.example
  bin/amnesic-vm-manager    # transient domain + tmpfs overlay sessions
```

## Conventions

- Shell: `set -o errexit -o nounset -o pipefail`, functions over inline blocks.
- Any `rm` with a variable in the path gets `${VAR:?}`. These run as root.
- Comments explain *why*, not *what*. A flag without a reason is a bug.
- Machine-specific values go in `vars.local.yml` (gitignored), never in
  `playbook.yml`.

## Current state

All files written and syntax-checked (`bash -n`, `xmllint`, YAML parse).
Nothing has been executed against hardware.

**Next action: Step 0 of `docs/TESTING.md`** — the `dmesg` IOMMU check on the
Ubuntu install. That single result decides whether Engine A is viable on this
laptop or whether it becomes a homelab-server project and Engine B is the
near-term path.

`docs/TESTING.md` is the working checklist. Fill in results and commit it as
you go; it is the record of what has actually been proven versus what is
still assumed.
