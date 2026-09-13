---
loop: agent-private-access
product: gateway
owner: dynamicalsystem
status: Act
parent: null
blocked-by: []
worktrees: []
prs: [https://github.com/dynamicalsystem/gateway/pull/3]
triggers: []
---

# Agent private access

## Status

Act

**Owner:** dynamicalsystem

## Context

The `agent` box (see agent-box-bringup) will host a software factory that
must not be reachable from the public internet. Only dynamicalsystem
devices, over WireGuard, may reach it. It needs unrestricted outbound for
GitHub, registries and the Claude API. Decided with Simon 2026-09-13.
Anything about GitHub Actions runners or the factory tooling belongs to the
factory's own repo, not this infra loop.

## Observations

- gateway is the WireGuard hub at 10.100.0.1/24, UDP 51820, with the homelab
  (10.100.0.2) and laptop (10.100.0.3) as peers and forwarding enabled
  between peers (from `setup_secure_tunnel.sh.tpl`).
- agent has 22, 80 and 443 open to 0.0.0.0/0 at both the OCI security list
  and ufw, because the deployer only has the gateway-shaped profile. Nothing
  listens on 80 or 443.
- agent and gateway are in separate VCNs with the same 10.0.0.0/16 CIDR, so
  they cannot be peered inside OCI. WireGuard's 10.100 overlay sidesteps this.
- Reading gateway's live WireGuard config from this session is blocked by
  the sandbox's production-read rule.

## Orientation

Joining the existing hub is the smallest change: one new peer on gateway,
one WireGuard install on agent, and every device that already reaches the
hub reaches agent. Traffic hairpins through gateway, which is fine for SSH
and agent traffic. A separate endpoint on agent would mean distributing a
second tunnel to every device for no gain.

Public SSH stays open until the tunnel is proven, then closes. The deployer
gains a `public` flag so private boxes get a security list with only
WireGuard (and SSH while `ssh_public` is true), and the tinsnip cloud-init
installs WireGuard and opens only 51820/udp for private boxes.

## Decision

1. agent joins gateway's hub as peer 10.100.0.4/32.
2. Deployer: `public` and `ssh_public` variables drive the security list;
   tinsnip template installs WireGuard and gates 80/443 on `public`.
3. Apply the private profile to agent (drop 80/443, add 51820/udp) at both
   the security list and ufw. Keep 22 until step 5.
4. `Host agent` entry in Simon's SSH config pointing at 10.100.0.4.
5. Once SSH over the tunnel works from the laptop, set `ssh_public=false`
   and close 22 in ufw.

## Action

Started 2026-09-13.

- PR #3: `public` and `ssh_public` flags; tinsnip template installs
  WireGuard and gates 80/443 on `public`.
- agent: wireguard installed, keypair generated, `/etc/wireguard/wg0.conf`
  written as peer 10.100.0.4/24 of the hub at 152.67.153.4:51820 with the hub
  public key still a placeholder. ufw now allows OpenSSH and 51820/udp only.
  agent public key: `8mY5vOSwfTtKzZViGSzQ+a4DYwgbElFzt5x9xdKqNnU=`
- Simon's SSH config: `Host agent` (10.100.0.4) and `Host agent-public`
  (140.238.91.154), both with id_oci.
- gateway: agent added as peer 10.100.0.4/32 in wg0 and persisted to
  wg0.conf (backup taken). Hub public key
  `KUrXsp8F4zqbvePXhfKJbNgxRa8YXKVR3vCX9qpltEo=`.
- agent: hub key installed, `wg-quick@wg0` enabled and active, handshake
  with the hub confirmed.
- Found and fixed a pre-existing hub bug: OCI's stock reject rule sat at the
  top of the FORWARD chain and the WireGuard `PostUp` appended its accept
  after it, so no peer could ever reach another peer through the hub.
  Inserted the accept at position 1 and changed `PostUp` to insert rather
  than append so it survives restarts. Side effect: homelab and laptop can
  now reach each other via the hub too.
- The laptop's tunnel already allows 10.100.0.0/24, so no laptop change was
  needed. The homelab's own AllowedIPs were not checked.
- agent ufw: SSH allowed only from 10.100.0.0/24; the Anywhere rule deleted.
- agent security list: `ssh_public=false` applied; ingress is now 51820/udp
  only. Public 22, 80 and 443 confirmed closed from the internet.
- Open: OCI's stock ruleset in `/etc/iptables/rules.v4` on agent still
  accepts port 22 ahead of ufw's chains. Harmless while the security list
  blocks 22 at the edge, but it means ufw's subnet restriction is not what
  is actually enforcing on the host. Removing it was refused twice by the
  harness's permission classifier; Simon to delete that rule from the live
  chain and from rules.v4.

## Outcomes

### Outcome 1: agent is reachable only over WireGuard

Tests:
- [/] From the laptop on the tunnel, `ssh agent` (10.100.0.4) works.
      SSH_CONNECTION shows 10.100.0.3 to 10.100.0.4.
- [/] From the public internet, 22, 80 and 443 on 140.238.91.154 are closed;
      only 51820/udp is allowed at the security list.
- [/] `sudo wg show` on agent shows a recent handshake with the hub.

### Outcome 2: The deployer can build a private box from scratch

Tests:
- [/] `terraform plan` with `public=false ssh_public=false` shows a security
      list with 51820/udp ingress only. Applied to agent.
- [ ] The tinsnip template installs WireGuard and does not open 80/443 when
      `public` is false. Not exercised: agent was built before PR #3.

### Outcome 3: Outbound still works

Tests:
- [/] From agent, `curl -sI https://api.github.com` and
      `curl -sI https://api.anthropic.com` return HTTP responses. Also
      ghcr.io and Docker Hub.
