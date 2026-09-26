---
loop: host-firewall-ufw-authority
product: gateway
owner: dynamicalsystem
status: Act
parent: null
blocked-by: []
worktrees: []
prs: []
triggers: []
---

# Host firewall: make ufw the authority

## Status

Act

**Owner:** dynamicalsystem

## Context

Opened 2026-09-26 from a backlog observation raised during
agent-private-access. Oracle's Ubuntu images ship their own persisted
iptables rules that sit ahead of ufw's chains, so ufw rules on our boxes do
not decide what gets in. On agent, ufw says SSH only from the WireGuard
subnet, but the stock rule accepts port 22 from anywhere first. Only the OCI
security list is actually keeping public SSH out.

## Observations

- On agent (2026-09-13), `iptables -S INPUT` showed a stock
  `-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT` before
  the `ufw-before-input` chain. It comes from `/etc/iptables/rules.v4`,
  loaded at boot by netfilter-persistent.
- On gateway, the INPUT chain has more stock and hand-added rules ahead of
  ufw: WireGuard 51820/udp, a `signal-over-wg` accept on 8010 from wg0, and
  accepts for 80 and 443 placed after ufw's chains but before the reject.
  The FORWARD chain had OCI's `REJECT --reject-with icmp-host-prohibited`
  ahead of everything, which is what broke peer forwarding until 2026-09-13.
- ufw on both boxes reports rules that are not what the kernel enforces.
- Both cloud-init templates (`setup_secure_tunnel.sh.tpl`,
  `setup_tinsnip_box.sh.tpl`) enable ufw but leave rules.v4 untouched.
- Deleting the stock rule on agent by hand was refused twice by the
  harness's permission classifier on 2026-09-13; it is still in place.

## Orientation

Two layers of firewall that disagree is worse than one. The OCI security
list is the edge and stays. On the host, ufw should be the single source of
truth, which means the stock netfilter-persistent rules must go rather than
be patched rule by rule: patching leaves the next surprise in place.

Options for the host:

1. Remove only the stock port-22 accept. Minimal, but leaves the rest of
   rules.v4 (and gateway's hand-added rules) outside ufw's view.
2. Stop netfilter-persistent loading rules.v4 at all (disable the unit or
   empty the file), and express every needed rule in ufw: 22 from the
   tunnel subnet (agent) or anywhere (gateway, until it too goes private),
   51820/udp, 80 and 443 on public boxes, 8010 on wg0 for signal, and the
   FORWARD accept for wg0 via ufw's `route allow` rules.
3. Drop ufw and manage iptables directly. More control, less legibility;
   nobody here wants to read raw iptables.

Option 2 is the honest one. The risk is on gateway, where a mistake locks
us out of a production box and can break WireGuard, Caddy and Signal at
once. Mitigations: do agent first (reachable only over the tunnel, so the
test is "does the tunnel still work"), keep an SSH session open during the
change on gateway, and prepare the exact ufw rule set from the live chain
before touching anything.

## Decision

Agreed with Simon 2026-09-26.

1. Both cloud-init templates disable netfilter-persistent and delete
   `/etc/iptables/rules.v4` and `rules.v6` before enabling ufw, so a fresh
   box starts with ufw as the only host firewall. WireGuard forwarding on
   hub boxes goes into ufw as a route rule instead of a wg0 PostUp iptables
   command.
2. Apply the same to agent by hand and verify over the tunnel.
3. Read gateway's live INPUT, FORWARD and NAT chains, translate every
   non-ufw rule into ufw rules, apply with a session held open, verify
   SSH, WireGuard, Caddy and Signal, then remove the stock rules.
4. Backlog item about duplicate PostUp rules on the hub is absorbed here.

Out of scope: making gateway private, and any change to the OCI security
lists.

## Action

Started 2026-09-26.

## Outcomes

### Outcome 1: ufw is the only host firewall on both boxes

Tests:
- [ ] On agent and gateway, `iptables -S INPUT` shows no accept or reject
      rules before the `ufw-before-input` chain other than ufw's own.
- [ ] `systemctl is-enabled netfilter-persistent` reports disabled or the
      unit is absent, and `/etc/iptables/rules.v4` is gone.
- [ ] A reboot of agent brings it back with the same ufw rule set and no
      stock rules.

### Outcome 2: Nothing that worked before stops working

Tests:
- [ ] agent: `ssh agent` over the tunnel works; public 22 still closed.
- [ ] gateway: SSH from the internet, HTTPS to a hosted site, WireGuard
      handshakes from laptop, homelab and agent, and Signal on 8010 over
      wg0 all work after the change.
- [ ] gateway: laptop can still reach agent through the hub (forwarding now
      via a ufw route rule).

### Outcome 3: New boxes get it right from first boot

Tests:
- [ ] A throwaway private box built from the updated tinsnip template
      passes Outcome 1's first two tests without manual steps. This also
      covers the untested cloud-init WireGuard path from agent-private-access.
