---
loop: agent-box-bringup
product: gateway
owner: dynamicalsystem
status: Act
parent: null
blocked-by: []
worktrees: []
prs: [https://github.com/dynamicalsystem/gateway/pull/2]
triggers: []
---

# Agent box bring-up

## Status

Act

**Owner:** dynamicalsystem

## Context

Simon wants a second Always Free A1 box, named `agent`, to run tinsnip
Quadlet units alongside `gateway`. Opened 2026-09-12 straight after
deployer-cleanup-and-state merged, using the fixed deployer for the first
time on a fresh deployment.

## Observations

- Limits API on 2026-09-12: A1 cores used 1 of 250, memory 6 of 1666 GB,
  VCNs 1 of 50. Capacity limits are not the constraint; the free hours are.
- Free A1 entitlement per Oracle docs: 1500 OCPU-hours and 9000 GB-hours a
  month. Usage 1 to 12 September: 283 OCPU-hours, 1697 GB-hours (the
  gateway box alone). Two 1 OCPU / 6 GB boxes for a 31-day month is
  1488 / 8928, inside the budget with almost no margin.
- The gateway cloud-init template builds a WireGuard hub and Caddy on
  Docker. tinsnip boxes need rootless podman, linger, and 22/80/443 open.
- The live gateway box runs Ubuntu 22.04 (image dated 2025-07-24). The
  newest A1 image is Ubuntu 24.04 dated 2026-08-25. tinsnip's README says
  podman 4.9.3, which is the 24.04 package.
- The deployer's compose inputs (.env, key and pubkey copies under
  ~/.config and ~/.local/share) do not exist on Simon's Mac. Terraform
  1.5.7, uv, and the SDK venv do.

## Orientation

Naming: with `TIN_SERVICE_NAME=agent` the deployer derives a separate state
file (`~/.local/state/dynamicalsystem/agent/terraform/terraform.tfstate`),
a separate VCN (`agent-prod-vcn`, DNS label `agentvcn`), and an instance
`agent-prod`. Nothing collides with gateway. The box's hostname is `agent`,
matching how the live box is `gateway`, so tinsnip's `hosts/agent/` is
the deploy target.

Budget: a second box at 1 OCPU / 6 GB fits. Anything larger overspends in
a full month. The boot volume adds 50 GB to a 200 GB allowance but, until
billing SR 16281429 resolves, will most likely bill at about GBP 2 a month
like gateway's does.

Running natively on the Mac avoids setting up the compose inputs and keeps
the state on the machine Simon already has.

## Decision

1. PR #2: add `setup_tinsnip_box.sh.tpl` (podman, uidmap, slirp4netns,
   fuse-overlayfs, git, ufw 22/80/443, linger, unprivileged ports from 80,
   hostname set to the service name) and an `ubuntu_version` variable.
2. Run the deployer natively from `~/work/gateway/main` with
   `TIN_SERVICE_NAME=agent`, `TF_VAR_ubuntu_version=24.04`,
   `TF_VAR_user_data_template` pointing at the new template, and a 12 hour
   retry deadline.
3. Shape 1 OCPU / 6 GB (Simon's choice).

## Action

- PR #2 merged 2026-09-12 (squash 5033a24).
- Deployer launched 2026-09-12 23:46 BST on Simon's Mac. Attempt 1 succeeded
  at 23:47 (41 seconds, no capacity retry). Public IP 140.238.91.154.
  Instance ocid ends `oh76udaq`, boot volume ocid ends `ot2tqi5`.
- Cloud-init finished at 22:49 UTC, 133 seconds after boot.
- Next: `hosts/agent/` in tinsnip and the OCI creds the box needs, per Simon.

## Outcomes

### Outcome 1: A second box exists, reachable over SSH, ready for tinsnip

Tests:
- [/] `terraform apply` succeeds and outputs a public IP. 140.238.91.154.
- [/] `ssh ubuntu@<ip>` with `~/.ssh/id_oci` works and `hostname -s` is `agent`.
- [/] `/var/log/tinsnip-first-boot.done` exists and `podman --version` is 4.9 or later. podman 4.9.3, Ubuntu 24.04.4.
- [/] `loginctl show-user ubuntu -p Linger` reports yes. ufw active with 22/80/443; unprivileged ports from 80.

### Outcome 2: The new deployer path behaves on a fresh deployment

Tests:
- [/] State lands at `~/.local/state/dynamicalsystem/agent/terraform/terraform.tfstate`.
- [/] The post-deploy inventory passes: two tagged instances, two attached volumes, 100 GB.
- [/] Gateway's own state still plans clean afterwards: 0 to add, 0 to destroy, the same 3 pending renames as before.

### Outcome 3: The box stays free

Tests:
- [ ] October invoice shows no A1 compute line for either box.
