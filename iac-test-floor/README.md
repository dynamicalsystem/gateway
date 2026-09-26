---
loop: iac-test-floor
product: gateway
owner: dynamicalsystem
status: Act
parent: null
blocked-by: []
worktrees: []
prs: [https://github.com/dynamicalsystem/gateway/pull/6, https://github.com/dynamicalsystem/gateway/pull/7, https://github.com/dynamicalsystem/gateway/pull/8, https://github.com/dynamicalsystem/gateway/pull/9, https://github.com/dynamicalsystem/gateway/pull/10]
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

- `.github/workflows` builds the image on push and on pull requests, but the
  build is the only check; nothing validates the Terraform, the templates,
  or the Python.
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

- PR #6: `check` job (fmt, validate, render both templates and `bash -n`
  them, py_compile, pytest); `classify()`, `classify_error()`,
  `deadline_exceeded()` pure and tested (11 tests); `scripts/tf_env.sh`,
  `scripts/plan_check.sh`, `scripts/probe.sh`; `ocpus` and `memory_in_gbs`
  variables. Two CI failures on the way, both real: unformatted Terraform,
  and `terraform console` printing multi-line strings as a heredoc.
- `plan_check.sh` immediately found gateway's three never-applied in-place
  changes (renames and tags on route table, security list, internet
  gateway). Applied; both boxes now plan clean.
- Found a zsh bug in `tf_env.sh` (`BASH_SOURCE` unset when sourced), which
  made `file(var.ufw_take_over_script)` fail at apply. Fixed with
  `git rev-parse --show-toplevel`.
- agent set up as deploy host: Terraform 1.9.5, uv, repo clone, OCI config
  and API key, SSH key pair, both live state files. Inventory and
  plan_check run there clean.
- First probe run from agent aborted in verify (set -e on a failed SSH,
  because agent lacked the private key) and left the box running. PRs #7,
  #8, #9, #10 followed: destroy from an EXIT trap, count boots instead of
  uptime, never abort on a failed check, drop a stray `fi` that CI had not
  caught (CI now runs `bash -n` on every script), drop a duplicated destroy
  block, and count ufw's IPv6 lines. The second run destroyed the stray box
  and passed every real check.
- Failure path (Decision 6): deployer run from agent with `ocpus=1000`
  exited 1 with "non-capacity error"; no instance or volume created; the
  VCN, subnet, gateway, route table and security list it had created were
  in state and destroyed with one command. The deployer deliberately does
  not destroy partial resources on a configuration error; persisted state
  is what makes them recoverable.

## Outcomes

### Outcome 1: A pull request cannot merge with broken IaC

Tests:
- [/] A PR that breaks `main.tf` formatting or validity, or a template
      render, shows a failed `check` on the PR before merge. Demonstrated
      twice on PR #6 itself.
- [/] pytest runs in CI and covers the inventory classification and the
      deployer's deadline and error classification.

### Outcome 2: Real-infrastructure checks are one command each

Tests:
- [ ] `scripts/probe.sh` run from agent deploys, verifies, and destroys a
      probe box, and the repeat-run plan shows no changes.
- [/] `scripts/plan_check.sh` run from agent reports no changes for gateway
      and agent.
- [/] A forced deployer failure exits non-zero and the inventory shows no
      orphan afterwards. Partial network resources were in state and
      destroyed.

### Outcome 3: The deployer has a home

Tests:
- [/] agent has Terraform, uv, the repo, credentials and both live state
      files; `terraform plan` for gateway and agent from agent is clean.
