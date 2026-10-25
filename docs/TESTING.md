# Hardware verification ladder

Nothing in this repo has been executed. This is the order in which to find
out whether it works, arranged so that each step is cheap to abandon.

Record results inline — this file is the lab notebook, commit it as you go.

---

## Step 0 — Does this machine have an IOMMU?

**Run on the existing Ubuntu install. Takes two minutes. Decides everything
downstream.**

```bash
dmesg | grep -i -e DMAR -e IOMMU
sudo journalctl -b | grep -i "DMAR: IOMMU enabled"
ls /sys/class/iommu/
```

Expected on a working machine: DMAR ACPI tables parsed, `DMAR: IOMMU enabled`,
and one or more entries under `/sys/class/iommu/`.

If empty, check BIOS for **VT-d** / *Intel Virtualization Technology for
Directed I/O*. On ASUS consumer boards this is frequently absent from the
setup menu even though the i7-1255U supports it. Some ASUS firmware exposes it
only after enabling *Advanced Mode* (F7 in the BIOS UI).

- [ ] DMAR tables present
- [ ] IOMMU enabled
- [ ] Result: ______________________

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
ansible-playbook -i localhost, -c local -K playbook.yml
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
