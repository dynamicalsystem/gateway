---
loop: iac-test-floor
product: gateway
owner: dynamicalsystem
status: Act
parent: null
blocked-by: []
worktrees: [iac-test-floor]
prs: []
triggers: []
---

# IaC test floor

## Status

Act

**Owner:** dynamicalsystem

## Context

Opened 2026-09-26. Every change to the deployer, the Terraform and the
cloud-init templates this month was tested by hand, once. The only CI is a
Docker image build that runs after merge. Simon asked whether the IaC needs
testing; the answer was yes, proportionately. Simon also offered the unused
`agent` box as the place to run the real-infrastructure checks.

## Observations

- `.github/workflows` builds the image on push to main only; nothing runs on
  pull requests, so "wait for checks then merge" was a no-op in this repo.
- Bugs found this month and what would have caught them:
  - cleanup targeting a resource name absent from the config: a unit test
    or a grep in CI.
  - state written to the container's tmp dir: only a second deploy on a
    fresh container (the restart test).
  - boot volume set to 20 GB: `terraform plan` against OCI.
  - old config deleting the hand-added WireGuard rule: import plus plan
    against the live box.
  - malformed script string in a cutover: rendering the template and
    `bash -n` on the result.
- The deployer runs natively on Simon's Mac; agent has nothing on it yet.

## Orientation

Two tiers. Automated floor in CI on every pull request: format, validate,
render both templates and syntax-check the output, compile the Python, and
unit-test the decision logic in the inventory and deployer with fake
objects. Real-infrastructure checks stay hand-run because they need
tenancy credentials and create resources: a scripted throwaway probe box,
and a plan-is-clean check against the live boxes. Running those from agent
rather than the Mac gives a stable, always-on place with the state files,
and lets the two remaining deployer tests (container restart, failure
path) be exercised for real.

Not worth it: mocking the OCI API for the apply path; plan or apply from
GitHub Actions with tenancy credentials.

## Decision

1. Workflow triggers on `pull_request` as well as push; a `check` job runs
   `terraform fmt -check`, `terraform validate`, renders both templates
   through `templatefile` and runs `bash -n` on the output, byte-compiles
   the Python, and runs pytest. The image build stays on push to main.
2. Pull the inventory's classification into a pure function and unit-test
   it: attached vs orphaned, tagged vs untagged, free-tier marker present or
   not inside and outside the allowance. Unit-test the deployer's retry
   deadline and error classification.
3. `scripts/probe.sh`: deploy a throwaway private box, verify over SSH
   (ufw alone, WireGuard present, ports, marker file, free-tier tag),
   destroy, confirm the inventory is back to baseline. Also runs the
   deployer a second time against the same state first, to prove a repeat
   run plans no changes (the container-restart test).
4. `scripts/plan_check.sh`: plan against gateway's and agent's state,
   expect no changes.
5. Set agent up as the deploy host: Terraform, uv, a clone of the repo, the
   OCI API key and SSH public key, state under `~/.local/state`. Run 3 and 4
   from there for real. Note for later: agent should get its own OCI user
   with a narrower policy than the tenancy admin key it borrows for now.
6. Failure path: force a non-capacity error (an impossible OCPU count) and
   confirm the deployer exits non-zero and leaves no orphan. True
   out-of-capacity cannot be forced; record that test as abandoned with
   that reason in deployer-cleanup-and-state.

## Action

Started 2026-09-26.

## Outcomes

### Outcome 1: A pull request cannot merge with broken IaC

Tests:
- [ ] A PR that breaks `main.tf` formatting or validity, or a template
      render, shows a failed `check` on the PR before merge.
- [ ] pytest runs in CI and covers the inventory classification and the
      deployer's deadline and error classification.

### Outcome 2: Real-infrastructure checks are one command each

Tests:
- [ ] `scripts/probe.sh` run from agent deploys, verifies, and destroys a
      probe box, and the repeat-run plan shows no changes.
- [ ] `scripts/plan_check.sh` run from agent reports no changes for gateway
      and agent.
- [ ] A forced deployer failure exits non-zero and the inventory shows no
      orphan afterwards.

### Outcome 3: The deployer has a home

Tests:
- [ ] agent has Terraform, uv, the repo, credentials and both live state
      files; `terraform plan` for gateway and agent from agent is clean.
