# Archived

- **Closed**: 2026-09-26 18:32 UTC
- **Status**: Succeeded
- **Summary**: CI check job on every PR (fmt, validate, template render, shell syntax, py_compile, pytest); hand-run plan_check and probe scripts; agent is the deploy host with credentials and both live states; failure path exercised.
- **Outcomes**: 6/6 tests passed.
- **Follow-up**: agent borrows the tenancy admin API key; a narrower OCI user for it is a backlog item.
