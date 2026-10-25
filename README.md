# ebb

Permanence + compartmentalisation (GrapheneOS model) with on-demand amnesic,
Tor-bound workspaces (Tails model).

Two engines:

- **Engine A — Qubes OS 4.3 + Whonix 18.** The real thing. Hardware-enforced
  isolation via VT-d.
- **Engine B — hardened Linux host + KVM/libvirt + Whonix KVM.** Fallback for
  hardware that can't run Qubes. Isolation is kernel-enforced, not
  hypervisor-enforced. Weaker, and you should know it's weaker.

---

## Deviations from the original specification

The spec was not followed literally. Each item below is a deliberate change,
with the reason.

### A1. `virt_mode hvm` on the Whonix DVM base — REJECTED

The spec says:

```bash
qvm-prefs <target_vm> virt_mode hvm
```

This is backwards. Qubes 4.x runs Linux qubes in **PVH** by default, which has
*no* emulated device model at all. HVM adds a QEMU stubdomain to emulate legacy
hardware — that is strictly more attack surface inside the isolation boundary.
Forcing HVM on a Whonix workstation downgrades it.

HVM is correct only when you need PCI passthrough or a non-Linux guest. An
anonymity workstation needs neither. **Kept at PVH.**

### A2. Building `sys-whonix-gateway` from scratch — REJECTED

Qubes 4.3 ships `whonix-gateway-18` and `whonix-workstation-18` templates and
builds `sys-whonix` and `whonix-workstation-18-dvm` for you during install (or
via `qubes-dom0-update qubes-template-whonix-gateway-18`). Hand-rolling a
parallel `sys-whonix-gateway` means you maintain it yourself forever and lose
the Whonix core addon's protections.

**We configure the stock `sys-whonix` and build our DVM base on top of the
stock Whonix workstation template.**

### A3. "Fail-closed network switch" via `qvm-firewall` — UNNECESSARY

Qubes is already fail-closed by construction. A qube's network exists only as a
virtual interface provided by its netvm. If `sys-whonix` dies, the interface is
gone — there is no fallback route to the physical NIC, because the child qube
has never had one. There is nothing to "drop".

Additionally, 4.3 added upstream enforcement
([#8551](https://github.com/QubesOS/qubes-issues/issues/8551)) specifically
preventing a Whonix-Workstation qube's netvm from being switched to
`sys-firewall` or any other clearnet netvm. The hole the spec wanted to plug is
welded shut in the core.

**Dropped. Replaced with an assertion check in `verify.sh` that confirms the
topology, rather than firewall rules that do nothing.**

### A4. "Multi-factor dom0 prompt" for clipboard — DOES NOT EXIST

Qubes RPC policy has three verbs: `allow`, `deny`, `ask`. There is no MFA
mechanism, and inventing one would mean writing dom0 code — the single worst
place in the system to add attack surface.

**Implemented as:** clipboard paste and file copy *out of* the anon disposables
into `vault` is `deny` (unconditional, no prompt to fat-finger). Into anything
else it's `ask` with `default_target=` unset, so you must type the destination
consciously. 4.3 also already blocks opening files/URLs from Whonix-Workstation
qubes in non-Whonix disposables
([#10051](https://github.com/QubesOS/qubes-issues/issues/10051)).

### B1. Entropy check against `/proc/sys/kernel/random/entropy_avail` — REMOVED

This is cargo cult. Since Linux 5.6, and conclusively since 5.18, the CRNG is
seeded once at boot from multiple sources and `/dev/urandom` never blocks
afterward. `entropy_avail` no longer tracks anything you can act on — it hovers
near 256 permanently on a healthy system and gating VM launch on it just adds a
spurious failure mode.

**Replaced with:** a one-time boot-level check that the kernel reported
`crng init done`, plus `rng-tools` installed and enabled if a hardware RNG is
present. That's the real version of the intent.

### B2. "RAM evacuation — overwrite host RAM with zeroes after `virsh destroy`" — THEATRE

You cannot, from userspace, reach into pages the kernel has already reclaimed
from a dead QEMU process and zero them. By the time `virsh destroy` returns,
those pages are back on the free list and outside your reach. Any script
claiming to do this is writing to its own memory, not the guest's.

The actual mechanism that gives you this property is a kernel boot flag:

```
init_on_free=1
```

which makes the kernel zero pages on free, system-wide, as a matter of course.

**Implemented in the kernel cmdline. The fake purge step is removed from the
daemon**, replaced with an explicit guest-RAM-is-not-swapped guarantee
(`memoryBacking/locked` + `nosharepages`) so guest RAM never hits disk in the
first place — which is the leak that actually matters forensically.

### B3. `lsm=landlock,lockdown,yama,apparmor,selinux` — CORRECTED

You cannot meaningfully run AppArmor and SELinux simultaneously as the primary
MAC; on any real distro one of them is unconfigured and does nothing while
breaking assumptions. The playbook detects the host family and emits
`...,selinux` on Fedora or `...,apparmor` on Debian/Ubuntu/Arch.

### B4. `page_poison=1` + `slub_debug=FZP` alongside `init_on_alloc/init_on_free` — TRIMMED

`page_poison=1` and `init_on_free=1` are redundant; the latter supersedes it.
`slub_debug=FZP` enables red-zoning, poisoning and sanity checks on every slab
object — it is a *debugging* facility with a double-digit percentage
performance cost and it disables slab merging implicitly, making
`slab_nomerge` redundant too.

**Kept:** `init_on_alloc=1 init_on_free=1 slab_nomerge
randomize_kstack_offset=on vsyscall=none spec_store_bypass_disable=on
page_alloc.shuffle=1 lockdown=confidentiality`.
**Dropped:** `page_poison=1`, `slub_debug=FZP`, `quiet loglevel=0`
(suppressing the log on a security box is actively counterproductive — you want
to see the IOMMU and crng messages).
**Conditional:** `tsx=off` is emitted only if the CPU actually has TSX; it is a
no-op on 12th gen and later.

### B5. `virsh snapshot-revert` for the clean slate — REPLACED

Internal qcow2 snapshots of a running domain are slow, fragile, and leave the
snapshot metadata on disk. The correct primitive for "pristine every launch" is
a **throwaway overlay with a read-only backing file**, created at launch and
`shred`-unlinked at teardown. The gold image is never written to, so there is
nothing to revert.

### B6. Clock decoupling

Correct requirement, but in Qubes and in Whonix KVM this is already handled by
`sdwdate` inside the gateway plus Whonix's own libvirt XML. The playbook
asserts `<clock offset='utc'>` with no `kvmclock` host passthrough rather than
reinventing it.

### B7. `Whonix-External` / `Whonix-Internal` described backwards — CORRECTED

The spec defines `Whonix-External` as "isolated internal network routing
strictly between the Gateway and Workstation". That is `Whonix-Internal`'s
job. In Whonix's actual topology:

| Network | Attached | Role |
|---|---|---|
| `Whonix-External` | Gateway only | Clearnet-facing. NAT to the host. Where Tor traffic leaves for the real internet. |
| `Whonix-Internal` | Gateway + Workstation | Isolated. No host IP, no NAT, no DHCP, no route anywhere. |

Building it as written gives the Workstation a leg on the clearnet bridge.
Everything still appears to work — Tor Browser loads, the Tor check page
passes — because the Workstation prefers its Tor route. The clearnet path just
sits there, available to anything that sets a source interface. **Built the
right way round.**

### B8. "Disable ptrace scoping" — INVERTED

`kernel.yama.ptrace_scope` scoping *is* the protection; disabling it means any
process can attach to any other process owned by the same user and read its
memory — browser reads password manager, and so on. The spec's own stated goal
(preventing cross-process leaks) requires the opposite.

**Set to `2`** (attach restricted to `CAP_SYS_PTRACE`). `3` disables ptrace
outright and cannot be lowered without a reboot; use that if you never debug
on this host.

---

## Order of operations — read this before running anything

Engine A requires VT-d. **Verify before you plan a disk layout:**

```bash
dmesg | grep -i -e DMAR -e IOMMU        # on any existing Linux install
```

No DMAR tables means no IOMMU means Qubes will install but `sys-net` and
`sys-usb` stop being real containment. On consumer ASUS/Acer/HP boards VT-d is
frequently absent from the BIOS even when the CPU supports it.

Once in Qubes, confirm with:

```bash
qubes-hcl-report <some-vm-name>
```

Both `VT-x` and `VT-d` must read `Active`.

**Test on an external NVMe SSD (aluminium enclosure, USB 3.2) before you touch
your internal disk.** Qubes has no live mode, and nesting it under
VMware/VirtualBox tests nothing useful — Xen-on-type-2 is unusably slow and
cannot exercise VT-d at all, which is the exact thing in question.

---

## Layout

```
hybrid-paradigm/
├── README.md
├── qubes/                      # Engine A — run in dom0
│   ├── bootstrap.sh
│   ├── verify.sh
│   ├── bin/anon-disp
│   ├── policy/30-hybrid-anon.policy
│   └── salt/
│       ├── hybrid-anon.top
│       └── hybrid-anon/init.sls
└── kvm/                        # Engine B — run on hardened host
    ├── ansible/
    │   ├── playbook.yml
    │   └── files/
    │       ├── 99-hardened.conf
    │       ├── whonix-external.xml
    │       └── whonix-internal.xml
    └── bin/amnesic-vm-manager
```
