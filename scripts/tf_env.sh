#!/bin/bash
# Source this to export the Terraform variables the deployer expects,
# from ~/.oci/config and the standard key locations. Usage: . scripts/tf_env.sh
eval "$(uv run --no-cache python - <<'PY'
import oci, os
c = oci.config.from_file()
print(f'export TF_VAR_tenancy_ocid={c["tenancy"]} TF_VAR_user_ocid={c["user"]} TF_VAR_fingerprint={c["fingerprint"]} TF_VAR_region={c["region"]} TF_VAR_compartment_ocid={c["tenancy"]}')
print(f'export TF_VAR_private_key_path={os.path.expanduser(c["key_file"].strip())}')
PY
)"
export TF_VAR_availability_domain="${TF_VAR_availability_domain:-rfAf:UK-LONDON-1-AD-1}"
export OCI_PUBLIC_SSH_KEY="${OCI_PUBLIC_SSH_KEY:-$HOME/.ssh/id_oci.pub}"
export OCI_PRIVATE_API_KEY="$TF_VAR_private_key_path"
export TF_VAR_ssh_public_key="$(cat "$OCI_PUBLIC_SSH_KEY")"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export TIN_NAMESPACE="${TIN_NAMESPACE:-dynamicalsystem}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export TF_VAR_ufw_take_over_script="$REPO_ROOT/scripts/ufw_take_over.sh"
