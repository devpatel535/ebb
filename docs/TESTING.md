# Hardware verification ladder

Nothing in this repo has been executed. This is the order in which to find
out whether it works, arranged so that each step is cheap to abandon.

Record results inline — this file is the lab notebook, commit it as you go.

---

## Step 0 — Does this machine have an IOMMU?

**Run on the existing Ubuntu install, on the metal. Takes two minutes.
Decides everything downstream.**

```bash
bash docs/step0-iommu-check.sh      # read-only; re-run with sudo if it says to
```

The script exists because the hand-run version of this check cannot tell
"the firmware does not expose VT-d" apart from "you are not allowed to read
dmesg". Both print nothing. One answer means abandoning Engine A; the other
means typing `sudo`. Exit codes: `0` not ruled out, `2` ruled out, `3`
indeterminate — go fix what it names and run it again.

### By hand

Four independent facts, ordered by what each one rules out.

```bash
# 1. Did the FIRMWARE publish a DMAR table?  == "is VT-d enabled in the BIOS"
#    The only fact here no kernel parameter can change.
ls -l /sys/firmware/acpi/tables/DMAR

# 2. Did the KERNEL bind an IOMMU, and actually partition devices behind it?
ls /sys/class/iommu/
ls /sys/kernel/iommu_groups/ | wc -l          # healthy VT-d box: dozens

# 3. What did the kernel say?  sudo is REQUIRED — see the warning below.
sudo journalctl -k -b | grep -i -e DMAR -e IOMMU    # preferred
sudo dmesg | grep -i -e DMAR -e IOMMU               # fixed-size ring; can evict

# 4. VT-x present?  Gates Engine A AND Engine B — same BIOS trip.
grep -w -o -e vmx -e svm /proc/cpuinfo | head -1
```

> **`dmesg` without `sudo` is a trap on Ubuntu.** Ubuntu ships
> `kernel.dmesg_restrict=1`, so an unprivileged `dmesg | grep DMAR` prints
> nothing on a machine whose IOMMU is working perfectly. The earlier version
> of this checklist ran it unprivileged. `kvm/ansible/playbook.yml` already
> notes this hazard for its CRNG check; it applies here too, where the stakes
> are the project's direction.

Prefer `journalctl -k -b` over `dmesg`: it is readable by members of `adm`
(Ubuntu's first user is one) and it is not a ring buffer, so early-boot DMAR
lines are still there on a desktop that has been up for days.

### Reading the log

| Line | Means |
|---|---|
| `DMAR: Intel(R) Virtualization Technology for Directed I/O` | `intel_iommu_init()` succeeded. **This** is the "it is up" line. |
| `DMAR-IR: Enabled IRQ remapping in x2apic mode` | Interrupt remapping is up. Xen requires this — see below. |
| `DMAR: DRHD base: …` / `DMAR: dmar0: reg_base_addr …` | Firmware tables parsed, remapping hardware found. |
| `DMAR: RMRR base: … end: …` | Reserved regions Xen must identity-map. Note how many; RMRR conflicts are a documented cause of `sys-usb` failing to start under Xen. |

**Do not grep for `DMAR: IOMMU enabled`.** The earlier version of this
checklist did, and it is wrong in the expensive direction. The kernel prints
that string from its *command-line parser*, only when `intel_iommu=on` was
passed explicitly. Modern kernels enable the Intel IOMMU by default, so on a
stock Ubuntu install with VT-d fully working **that string is absent**.
Reading its absence as "no IOMMU" sends you to Engine B on a machine that
could have run Engine A — and nothing downstream would ever contradict it.

### Why interrupt remapping is a gate, not a detail

Xen refuses to enable VT-d when interrupt remapping is unavailable, unless
booted with `iommu=no-intremap`. Without remapping, a device behind the IOMMU
is still DMA-constrained but can inject interrupts it was never assigned —
which is an escape from its driver domain, and driver-domain containment is
the entire reason `sys-net` and `sys-usb` exist. So "IOMMU yes, remapping no"
is not a partial win. For this project it is the same answer as no IOMMU,
reached after buying an enclosure instead of before. Check it here, for free.

### What this step can and cannot prove

It can **rule out** Engine A: no DMAR table means no IOMMU means `sys-net`
and `sys-usb` are not containment, and no amount of Qubes configuration
changes that.

It cannot **confirm** Engine A. Xen does its own DMAR parsing and carries its
own quirk list, and will disable VT-d on hardware Linux is perfectly happy
with. The authoritative test stays Step 2, in dom0:
`xl info | grep virt_caps` → wants `hvm hvm_directio`. Step 0 is the cheap
filter that stops you buying an enclosure for nothing, not a green light.

### Results

- [ ] Bare metal, not a VM (the script refuses otherwise — a hypervisor
      answers for its emulated platform, which is not the question)
- [ ] `/sys/firmware/acpi/tables/DMAR` present
- [ ] `/sys/class/iommu/` non-empty: ______________________
- [ ] `/sys/kernel/iommu_groups/` count: ______
- [ ] `DMAR: Intel(R) Virtualization Technology for Directed I/O` seen
- [ ] `DMAR-IR: Enabled IRQ remapping` seen
- [ ] RMRR region count: ______
- [ ] VT-x (`vmx`) present
- [ ] Kernel: ______________________  Date: ____________
- [ ] **Result: ______________________**

### Decision

| DMAR table | `/sys/class/iommu` | Remapping | Verdict |
|---|---|---|---|
| absent | empty | — | **Engine A ruled out.** BIOS first (below). If the toggle is not there, Engine A becomes a homelab-server project and Engine B is the near-term path. |
| present | empty | — | **Not decided yet.** The kernel chose not to enable it. Check `grep IOMMU_DEFAULT_ON /boot/config-$(uname -r)`, add `intel_iommu=on` to `GRUB_CMDLINE_LINUX_DEFAULT`, `update-grub`, reboot, re-run. Record nothing until then. |
| present | `dmar0`… | absent | **Engine A ruled out effectively.** See the remapping section above. Look for an interrupt-remapping or x2APIC setting in BIOS; if absent, take Engine B. |
| present | `dmar0`… | present | **Engine A not ruled out.** Proceed to Step 1/2. Still unconfirmed until `xl info` in dom0. |
| — | — | — | **No `vmx` at all → both engines blocked.** KVM needs VT-x too, so there is no fallback to take until the BIOS is fixed. |

### If you need to change BIOS settings

Look for **VT-d** / *Intel Virtualization Technology for Directed I/O*. On
ASUS consumer boards it is frequently absent from the setup menu even though
the i7-1255U supports it; some ASUS firmware exposes it only after enabling
*Advanced Mode* (F7 in the BIOS UI), typically under *Advanced → System Agent
(SA) Configuration*.

> **Have the BitLocker recovery key for the Windows partition in hand first.**
> Firmware setting changes alter the TPM measurements BitLocker seals
> against, and a VT-d toggle is quite enough to drop Windows into recovery on
> the next boot. This machine already has a BitLocker/GRUB fix path in play
> (see Step 3). Pull the key from your Microsoft account, or
> `manage-bde -protectors -get C:` from an elevated prompt, *before* you
> reboot into setup. Do not turn a two-minute check into a lost evening.

**If no IOMMU:** Engine A still installs, but `sys-net` and `sys-usb` stop
being containment — a malicious NIC or USB controller can DMA into dom0.
At that point Engine B on the current Ubuntu install is the better use of
effort, and Engine A becomes a homelab-server project.

---

## Step 1 — Whonix under VMware on Windows

Zero risk, tests the anonymity workflow only. The question this answers is
"do I actually want to live behind Tor", before restructuring a disk for it.

Known friction on this machine: VMware and WSL2 already conflict. Expect to
toggle Hyper-V / VBS off, which will break WSL1 Kali until toggled back.

- [ ] Whonix 18 Gateway + Workstation import cleanly
- [ ] `check.torproject.org` confirms Tor from the Workstation
- [ ] Workstation has **no** second NIC on a clearnet bridge
- [ ] Snapshot revert produces a clean session
- [ ] Verdict: ______________________

---

## Step 2 — Qubes 4.3 on an external NVMe SSD

**The real test. Do not skip to Step 3.**

Qubes has no live mode (dropped after 3.2), and nesting it under
VMware/VirtualBox tests nothing useful — Xen on a type-2 hypervisor is
unusably slow and cannot exercise VT-d at all, which is the exact property in
question.

Install to an external NVMe in an aluminium USB 3.2 enclosure. Boot via the
F2/Esc boot menu. The internal disk and its bootloader are untouched.

```bash
# in dom0, immediately after install
qubes-hcl-report work          # writes the report into the named qube
xl info | grep virt_caps       # want: hvm hvm_directio
```

- [ ] `VT-x: Active`
- [ ] `VT-d: Active`
- [ ] Wi-Fi works in `sys-net`
- [ ] Audio works
- [ ] **Suspend / resume works** — the usual Alder Lake casualty
- [ ] External display works
- [ ] Battery life acceptable: ______ hours
- [ ] Qubes 4.3 + Whonix 18 templates install

Then the actual repo:

```bash
# transfer in — dom0 has no network, never curl into it
qvm-run --pass-io <vm> 'cat /home/user/ebb.tar.gz' > ebb.tar.gz
tar xzf ebb.tar.gz && cd ebb/qubes
./bootstrap.sh
./verify.sh
```

- [ ] `bootstrap.sh` completes
- [ ] `verify.sh` — all assertions pass
- [ ] `anon-disp` launches a Tor-bound disposable
- [ ] Clipboard out of the disposable to `vault` is **denied**
- [ ] `qvm-copy` out of the disposable is **denied**

**Live on it for a week or two before Step 3.** Suspend failures and battery
drain only become real once you're carrying the machine around.

- [ ] Verdict: ______________________

---

## Step 3 — Internal disk

Only if Steps 0 and 2 both pass cleanly. Two open problems first:

**Disk arithmetic.** 512GB already split Windows / Ubuntu / Kali. Qubes'
stated 32GB minimum is fiction — Fedora 42, Debian 13 and Whonix 18 templates
plus disposables want 150GB+ to not be miserable. The Kali partition is
largely redundant given Kali already runs on WSL1.

- [ ] Space available for Qubes: ______ GB

**Secure Boot collision.** Qubes ships Xen, which is not shim-signed; Secure
Boot is not supported out of the box. The existing BitLocker/GRUB fix path
(re-enable Secure Boot with a Microsoft-signed shim) is mutually exclusive
with adding Qubes to the same boot chain. Pick one.

- [ ] Decision: ______________________

**Also worth weighing: don't.** Qubes explicitly discourages dual-boot —
Windows can overwrite the bootloader on update, and a compromised Windows can
tamper with Qubes boot files, since dom0 cannot defend what another OS can
write. Given the disk pressure and the Secure Boot conflict, keeping Qubes
permanently on the external SSD may simply be the correct answer rather than
a consolation prize.

- [ ] Final placement: ______________________

---

## Engine B verification (parallel track)

Runs today on the Ubuntu install regardless of the VT-d outcome.

```bash
cd ebb/kvm/ansible
cp vars.local.yml.example vars.local.yml   # set whonix_version + key fpr

# -e @vars.local.yml is NOT optional. playbook.yml defines
# whonix_signing_key_fpr: "CHANGE_ME" and whonix_version: "" in its own vars
# block and has no vars_files, so without -e the file you just filled in is
# never read and the playbook stops at its own signing-key gate.
ansible-playbook -i localhost, -c local -K -e @vars.local.yml playbook.yml

sudo reboot                                 # kernel cmdline changes
```

After reboot:

```bash
cat /proc/cmdline                           # confirm hardened params applied
sudo amnesic-vm-manager status
sudo amnesic-vm-manager start
```

- [ ] Kernel cmdline shows `init_on_free=1`, `lockdown=confidentiality`
- [ ] `module.sig_enforce=1` did **not** break DKMS modules you need
- [ ] `virbr2` has no host IP
- [ ] `/run/amnesic` is tmpfs
- [ ] Session starts, Tor works, teardown leaves no overlay
- [ ] Gold image mtime unchanged after a session
