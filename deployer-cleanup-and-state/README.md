---
loop: deployer-cleanup-and-state
product: gateway
owner: dynamicalsystem
status: Act
parent: null
blocked-by: []
worktrees: [deployer-cleanup-and-state]
prs: [https://github.com/dynamicalsystem/gateway/pull/1]
triggers:
  - when: Oracle answers billing support request 16281429
    then: "Record whether new volumes in this tenancy rate as Always Free"
---

# Deployer cleanup and state

## Status

Act

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
- `terraform/terraform.tfstate` in the Documents clone is a 0-byte untracked
  file; it was never committed.
- The live default security list carries a hand-added WireGuard rule
  (UDP 51820, description "Wireguard") that is not in `main.tf`. Found by
  importing the live resources and planning: the plan would have removed it.
- `source_details.source_id` resolves to the newest Canonical Ubuntu 22.04
  image at plan time. A new image publication changes it, and that attribute
  forces instance replacement. Same for `metadata.user_data` and
  `hostname_label`. Nothing in the config guarded against this.

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

Root cause of the charge, established 2026-09-14 from per-volume usage
history: August 2025 had 19 boot volumes (722 GB-months, GBP 14.72) from
the retry loop running with lost state. That exceeded the 200 GB allowance,
so every volume was correctly rated paid, including gateway's, created
2025-08-13 into that state. After cleanup the tenancy has held one 50 GB
volume since October 2025, but Oracle's documented automatic transition
from paid to Always Free never fired. The agent volume, created 2026-09-12
inside the allowance, produces no block volume usage rows at all, so it is
rated free. The gateway volume is stuck, not misconfigured: there is no
free-tier setting on a volume. Fallback if Oracle does not fix it: clone
the boot volume into a fresh one and swap it in.

## Decision

Agreed with Simon on 2026-09-12, including the naming convention and tagging the live instance in place.

1. Add a `backend "local" {}` block to `main.tf` so the state path passed at
   init is honoured, and store state under the mounted `/state` volume. Remove
   the 0-byte `terraform/terraform.tfstate` and gitignore `*.tfstate*`.
2. Fix the cleanup target to the instance resource that exists, and make
   cleanup failure log the actual stderr instead of "may have failed".
3. Set `boot_volume_size_in_gbs` to 50. Simon asked for 49; OCI rejects boot
   volumes under 50 GB at launch, so 50 is the floor. The comment states the
   OCI minimum and the 200 GB Always Free allowance.
4. Add `scripts/oci_inventory.py` (from the session scratchpad) and run it at
   the end of a successful deploy; exit non-zero and log if any boot or block
   volume is unattached or any instance carries no `managed-by` tag.
5. Bound the retry loop with a retry deadline: elapsed clock time after which
   the deployer gives up. Default 24 hours, overridable by
   `GATEWAY_RETRY_DEADLINE_HOURS`.
6. Naming convention:
   - Instance display name and hostname label are `<service>-<environment>`,
     matching the tinsnip service user (`gateway-prod`). OCI derives the boot
     volume name from the instance name.
   - VCN and subnet use the same stem: `<service>-<environment>-vcn`,
     `<service>-<environment>-subnet`.
   - Every resource carries freeform tags `service`, `environment`, and
     `managed-by=terraform`.
   - `service` and `environment` are Terraform variables fed from
     `TIN_SERVICE_NAME` and the tinsnip environment the container already has.
   - Applies to new deployments. The live instance's display name can be
     updated in place; its hostname label and VCN are left alone because
     changing them forces replacement.

Out of scope: removing `main.py` Resource Manager mode, the route-sync files,
and anything about the Oracle rating problem itself.

## Action

Started 2026-09-12. Data-plane worktree `~/work/gateway/deployer-cleanup-and-state`
on branch `deployer-cleanup-and-state`.

- Live instance, VCN, and subnet renamed and tagged in place per the
  convention (display names only; hostname label and DNS labels untouched).
- Branch `deployer-cleanup-and-state`: backend block, naming variables and
  tags, 50 GB boot volume, `lifecycle.ignore_changes` on image, metadata and
  hostname label, the WireGuard rule declared, cleanup target fixed with real
  stderr, retry deadline (`GATEWAY_RETRY_DEADLINE_HOURS`, default 24), post-deploy
  inventory check, `scripts/oci_inventory.py`, `scripts/import_existing.py`,
  Dockerfile and compose updated, emoji removed from log lines.
- Verified locally with Terraform 1.5.7: `terraform init -backend-config=path=`
  wrote state to the given path; all six live resources imported; plan is
  0 to add, 3 to change (rename and tag the route table, security list and
  internet gateway), 0 to destroy.
- The verified state was copied to
  `~/.local/state/dynamicalsystem/gateway/terraform/terraform.tfstate` on
  Simon's Mac, which is the standalone-mode path the compose file mounts.
  If the container runs on a tinsnip host, that host's `/state` mount needs
  the same file, or `scripts/import_existing.py --run` executed there once.
- Inventory run against the tenancy passes: one tagged instance, one attached
  volume, 50 GB total.

## Outcomes

### Outcome 1: A container restart does not create a second instance

Tests:
- [ ] With a deployed instance, restart the gateway container; `terraform plan`
      reports no changes and the tenancy still has exactly one instance.
- [/] The state file exists under the mounted `/state` path on the host after
      the first successful apply. Verified locally: init honoured the backend
      path and wrote a 36 KB state there after import.

### Outcome 2: A failed apply leaves no unattached volume

Tests:
- [ ] Simulate a capacity failure (for example, request more OCPUs than the
      A1 limit allows) and confirm the inventory shows no orphaned boot or
      block volume after the retry loop gives up or is stopped.
- [/] `cleanup_failed_deployment` targets a resource name that exists in
      `main.tf`. Verified by grep; `terraform validate` passes.

### Outcome 3: Orphans are detected, not discovered on an invoice

Tests:
- [/] `scripts/oci_inventory.py` runs against the tenancy with the `.oci`
      config and prints instances, volumes, attachments, and total GB.
- [ ] After a successful deploy, the deployer runs the inventory and exits
      non-zero if any volume is unattached.

### Outcome 4: The Terraform config is honest about the free tier

Tests:
- [/] `boot_volume_size_in_gbs` is 50 and the comment states the OCI minimum
      and the 200 GB allowance.
- [/] `terraform plan` against the live tenancy shows no change to the boot
      volume size.

### Outcome 5: Resources are identifiable by name and tag

Tests:
- [ ] A fresh deploy with `service=gateway environment=test` produces an
      instance, VCN, and subnet named per the convention, each tagged
      `service`, `environment`, `managed-by=terraform`.
- [/] The inventory check lists the live instance as untagged until it is
      tagged in place, and clean afterwards. Tagged 2026-09-12; passes.
