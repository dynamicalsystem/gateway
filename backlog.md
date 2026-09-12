# Backlog

Cross-loop triggers and observations that outlive their owning loops.

## Triggers

- [ ] when: Oracle answers billing support request 16281429
      then: "Record in deployer-cleanup-and-state Orientation whether new volumes in this tenancy rate as Always Free; if not, every orphan the deployer leaves is billed at full rate"

## Observations

- 2026-09-12 gateway: console banner says Always Free Ampere A1 compute
  entitlements have changed. Watch the next invoice for a new A1 line.
- 2026-09-12 gateway: the support API (CIMS) returns 403 for this tenancy
  because there is no My Oracle Support link. Tickets go via the console.
- 2026-09-12 gateway: main.py (Resource Manager mode) polls a hard-coded
  stack OCID. Unused now Terraform mode is the default; candidate for removal.
- 2026-09-12 gateway: the Documents clone has untracked route-sync files
  (Caddyfile.template, sync_routes.sh, setup_route_sync.sh, teardown_route_sync.sh,
  README_ROUTE_SYNC.md, ROUTE_SYNC_SETUP.md). Decide whether they belong in the repo.
- 2026-09-12 gateway: README's "Tinsnip Deployment" section describes a
  service-user and machine/setup.sh model that no longer exists. Current
  tinsnip is a Quadlet repo where `gateway` is the hostname of the Oracle box;
  the deployer is a hand-run bootstrap tool, not a tinsnip unit. Rewrite the
  README section or delete it.
