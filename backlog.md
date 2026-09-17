# Backlog

Cross-loop triggers and observations that outlive their owning loops.

## Triggers

- [x] when: Oracle answers billing support request 16281429
      then: "Record in deployer-cleanup-and-state Orientation whether new volumes in this tenancy rate as Always Free; if not, every orphan the deployer leaves is billed at full rate"
      resolved: 2026-09-14 UTC. Billing replied that rating disputes are Technical Support's; superseded by the trigger below.
- [~] when: Oracle answers technical support request 4-0003772067 (Billing & Cost Management > Billing > Subscription Usage and Rate Card)
      then: "Record whether both boot volumes (gateway-prod, agent-prod) now rate as Always Free and whether credits were issued; if not, decide whether to keep the agent box"
      progress: 2026-09-17 Oracle Operations converted the gateway volume to free tier; it now carries system tag orcl-cloud.free-tier-retained=true. Usage rows through 17 Sep still show cost (conversion landed mid-day); confirm zero-cost rows from 18 Sep. Credits for past invoices not yet addressed. The agent volume was already rating free (no usage rows since creation).

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
- 2026-09-13 gateway: the hub's wg0 PostUp and PostDown leave duplicate
  FORWARD accepts and MASQUERADE rules behind across restarts (four accepts,
  three masquerades, two rejects seen). Harmless but untidy; clean up and
  guard the template's rules against duplication when next touching it.
- 2026-09-13 gateway: the hub rejects ICMP from peers, so pinging 10.100.0.1
  is not a valid tunnel test; use TCP to port 22.
- 2026-09-13 gateway: the gateway and tinsnip cloud-init templates both
  leave OCI's stock rules.v4 in place, which accepts port 22 ahead of ufw.
  Either template should remove that rule so ufw is the single source of
  truth on the host.
