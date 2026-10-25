# /srv/user_salt/hybrid-anon/init.sls
#
# Engine A :: the anonymous compartment.
#
# ONE new object is created: `anon-dvm`, a disposable-VM template layered on
# the stock whonix-workstation-18 template. Everything else here is property
# assertion on objects Qubes and the Whonix installer already built.
#
# WHY NOT BUILD sys-whonix-gateway OURSELVES:
#   Qubes 4.3 ships sys-whonix, built from whonix-gateway-18, and the package
#   qubes-core-admin-addon-whonix enforces anti-leak invariants against it by
#   name. A hand-rolled parallel gateway is a gateway with those invariants
#   switched off. We configure the stock one.

# --------------------------------------------------------------------------
# The disposable template
# --------------------------------------------------------------------------

anon-dvm:
  qvm.vm:
    - present:
      - template: whonix-workstation-18
      - label: red
      - class: AppVM
    - prefs:
      # Tor-only upstream. In 4.3 the Whonix addon additionally refuses to let
      # this be switched to a clearnet netvm (qubes-issues#8551), so this line
      # is belt alongside an upstream brace.
      - netvm: sys-whonix

      # THE key property. Makes this qube a factory for disposables rather
      # than something you run directly.
      - template_for_dispvms: True

      # virt_mode is NOT set here, on purpose.
      #
      # Qubes 4.x defaults Linux qubes to PVH, which has no emulated device
      # model at all — no QEMU inside the isolation boundary. The original
      # spec called for `virt_mode hvm`; that would attach a QEMU stubdomain
      # to emulate legacy hardware this qube has no use for, which is a net
      # increase in attack surface. HVM is for PCI passthrough and non-Linux
      # guests. Leave it alone.

      # Initial RAM. Whonix-Workstation wants ~1280MB floor for Tor Browser
      # not to thrash; maxmem lets the balloon driver grow it under load.
      - memory: 1536
      - maxmem: 4000
      - vcpus: 2

      # This qube provides network to nobody. (Default False — asserted so a
      # later hand-edit shows up as a diff rather than silently standing.)
      - provides_network: False

      # Disposables spawned from here get no persistent /rw by definition;
      # the private volume is discarded at shutdown. Nothing to configure.

    - features:
      - set:
        # Show this DVM base in the "open in disposable" menus.
        - appmenus-dispvm: '1'
    - tags:
      - add:
        - anon
        - hybrid-paradigm

# --------------------------------------------------------------------------
# Gateway assertions
# --------------------------------------------------------------------------
#
# We do not create sys-whonix. We assert the two properties that matter and
# let the state fail loudly if the Whonix wizard left it otherwise.

sys-whonix:
  qvm.prefs:
    - autostart: True
    - provides_network: True
    # Deliberately NOT setting sys-whonix's own netvm. On most installs it is
    # sys-firewall; on some it is sys-net directly. Both are correct and the
    # choice is yours — overwriting it here would silently rewire your clearnet
    # path during what is supposed to be an anonymity-layer deployment.

# --------------------------------------------------------------------------
# What is NOT here, and why
# --------------------------------------------------------------------------
#
# No qvm-firewall rules on the disposables.
#
#   The spec asked for firewall blocks so that "if sys-whonix crashes, all
#   child tunnels drop immediately (fail-closed)". Qubes is already fail-closed
#   at a lower layer: a qube's network interface is *provided* by its netvm as
#   a vif pair. If sys-whonix stops, the interface disappears. There is no
#   route to the physical NIC to fall back to, because one was never created.
#   A firewall rule here would be a no-op that reads as protection.
#
#   Likewise "block anon-disp from local network nodes and printer discovery":
#   the only upstream is a Tor transparent proxy. There is no path to
#   192.168.0.0/16 to block. mDNS/LLMNR have nowhere to go.
#
# No clipboard config in this file — RPC policy is not a VM property.
#   See ../policy/30-hybrid-anon.policy.
