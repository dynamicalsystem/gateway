---
loop: deployer-cleanup-and-state
product: gateway
owner: dynamicalsystem
status: Decide
parent: null
blocked-by: []
worktrees: []
prs: []
triggers:
  - when: Oracle answers billing support request 16281429
    then: "Record whether new volumes in this tenancy rate as Always Free"
---

# Deployer cleanup and state

## Status

Decide

**Owner:** dynamicalsystem

## Context

On 2026-09-12 Simon asked why the OCI tenancy is billed monthly for
B91961 (Block Volume Storage) and B91962 (Block Volume Performance Units),
suspecting the gateway deployer was leaving billable volumes behind.

The charge turned out to be the single live boot volume of `gateway-instance`
(50 GB, Balanced, home region), which Oracle rates as paid despite the
documented 200 GB Always Free allowance. That is an Oracle-side problem and is
being handled by billing support request 16281429.

While tracing it, three real bugs surfaced in the retry deployer. None causes
the current charge. All would cause exactly the orphaning Simon suspected the
next time the retry loop runs, and on this tenancy every orphan is billed at
full rate. This loop fixes them.

## Observations

Tenancy state, read-only via the OCI SDK on 2026-09-12:

- One region (uk-london-1), one compartment (root), one instance, one 50 GB
  boot volume attached to it. No block volumes, no orphaned boot volumes, no
  backups. Total volume storage 50 GB.
- Usage API attributes every B91961 and B91962 line since at least 2026-05 to
  that one boot volume OCID. A1 compute on the same instance costs zero.
- Invoices are about GBP 2.04 per month, which is those two lines plus VAT.

Code, `terraform_deploy.py` and `terraform/main.tf` at commit 73ed685:

- `cleanup_failed_deployment` runs
  `terraform destroy -target=oci_core_instance.free_instance`. The resource in
  `main.tf` is `oci_core_instance.gateway_instance`. The target does not exist,
  so cleanup after a capacity failure is a no-op and the warning is swallowed.
- `init_terraform` copies the Terraform tree to `/tmp/terraform-work` and runs
  `terraform init -backend-config='path=<XDG_STATE_HOME>/.../terraform.tfstate'`.
  `main.tf` declares no `backend` block, so Terraform ignores the flag and
  writes state to `/tmp/terraform-work/terraform.tfstate` inside the container.
  State is lost on every container restart. `docker-compose.yml` already mounts
  a `/state` volume for exactly this purpose.
- `main.tf` sets `boot_volume_size_in_gbs = "20"` with the comment
  "Max 20 for free tier". OCI's minimum boot volume is 50 GB and the Always
  Free allowance is 200 GB. The live volume is 50 GB, so this value has never
  been what got applied; the API reports `boot_volume_size_in_gbs: None` on the
  instance source details.
- Git history (commits 360fb1c, 789f486, "cleanup script debug and tether
  future deployments to a single vcn", "terraform retry bug") and the existence
  of `cleanup_vcns.py` show that VCNs already piled up once from repeated
  applies with lost state.
- `check_capacity_error` lists `CannotAttachVolume` as a capacity error and
  retries on it. That error can leave a created-but-unattached volume behind.
- `deploy_with_retry` retries every 60 seconds forever on capacity errors,
  with no upper bound on attempts or wall time.
- `terraform/terraform.tfstate` in the repo is a 0-byte file and is not
  gitignored.

## Orientation

The deployer has two independent failure modes that both end in billable
resources nobody is tracking:

1. **State loss.** Without persistent state, every run after a restart is a
   fresh `apply`: a new VCN (until the VCN limit trips), a new instance, and a
   new boot volume. The old instance keeps running and its volume keeps
   billing. This is the mechanism behind the earlier VCN pile-up. The fix is a
   `backend "local"` block so the `-backend-config` path is honoured, pointing
   at the already-mounted `/state` volume. Alternatively the state path can
   simply be a `TF_DATA_DIR`/`-state` argument, but a backend block is the
   idiomatic form and survives `terraform init` reruns.

2. **Cleanup that does nothing.** Even with state, a failed apply on a
   capacity error can leave partial resources. The cleanup step exists for
   this but targets a resource name from a previous config. Fixing the target
   name is trivial. Whether `-target` destroy of the instance is the right
   cleanup at all is worth a thought: with persistent state, Terraform's next
   apply will reconcile partial resources itself, so the cleanup step may be
   unnecessary. It should at minimum not be silently wrong.

The 20 GB boot volume line is not a billing risk but is misleading and, if
Terraform ever did send it, OCI would reject it. It should be 50 with an
accurate comment.

Whether orphans cost money depends on Oracle's answer to ticket 16281429.
If the tenancy rates all volumes as paid, each orphan costs about GBP 2 a
month indefinitely, which raises the value of a guard that detects them.

A cheap guard already exists: the read-only inventory script used to diagnose
this (instances, boot volumes, block volumes, attachments, backups, total GB).
Running it after a successful deploy and failing loudly on any unattached
volume would have made today's investigation a two-minute check.

## Decision

Proposed, pending Simon's agreement:

1. Add a `backend "local" {}` block to `main.tf` so the state path passed at
   init is honoured, and store state under the mounted `/state` volume. Remove
   the 0-byte `terraform/terraform.tfstate` and gitignore `*.tfstate*`.
2. Fix the cleanup target to `oci_core_instance.gateway_instance`, and make
   cleanup failure log the actual stderr instead of "may have failed".
3. Set `boot_volume_size_in_gbs` to 50 and correct the comment to state the
   OCI minimum and the 200 GB Always Free allowance.
4. Add `scripts/oci_inventory.py` (from the session scratchpad) and run it at
   the end of a successful deploy; exit non-zero and log if any boot or block
   volume is unattached.
5. Bound the retry loop with a configurable maximum wall time, defaulting to
   something generous like 24 hours, so a misconfiguration cannot spin forever.

Out of scope: removing `main.py` Resource Manager mode, the route-sync files,
and anything about the Oracle rating problem itself.

## Action

Not started. Data-plane worktree to be created as
`~/work/gateway/deployer-cleanup-and-state` on a branch of the same name.

## Outcomes

### Outcome 1: A container restart does not create a second instance

Tests:
- [ ] With a deployed instance, restart the gateway container; `terraform plan`
      reports no changes and the tenancy still has exactly one instance.
- [ ] The state file exists under the mounted `/state` path on the host after
      the first successful apply.

### Outcome 2: A failed apply leaves no unattached volume

Tests:
- [ ] Simulate a capacity failure (for example, request more OCPUs than the
      A1 limit allows) and confirm the inventory shows no orphaned boot or
      block volume after the retry loop gives up or is stopped.
- [ ] `cleanup_failed_deployment` targets a resource name that exists in
      `main.tf`; a unit test or a `terraform validate` with the target proves it.

### Outcome 3: Orphans are detected, not discovered on an invoice

Tests:
- [ ] `scripts/oci_inventory.py` runs against the tenancy with the `.oci`
      config and prints instances, volumes, attachments, and total GB.
- [ ] After a successful deploy, the deployer runs the inventory and exits
      non-zero if any volume is unattached.

### Outcome 4: The Terraform config is honest about the free tier

Tests:
- [ ] `boot_volume_size_in_gbs` is 50 and the comment states the OCI minimum
      and the 200 GB allowance.
- [ ] `terraform plan` against the live tenancy shows no change to the boot
      volume size.
