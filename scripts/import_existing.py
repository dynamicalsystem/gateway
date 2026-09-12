#!/usr/bin/env python3
"""Seed Terraform state from resources that already exist in the tenancy.

Use this once when moving a deployment onto persistent state, so the next
`terraform apply` reconciles the live instance instead of creating a second
one. Finds the running instance and its VCN by the service/environment tags
(falling back to the only running instance) and prints or runs the matching
`terraform import` commands.

Usage:
  scripts/import_existing.py              # print the commands
  scripts/import_existing.py --run        # run them in ./terraform
Credentials come from TF_VAR_* or ~/.oci/config, as for oci_inventory.py.
"""

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from oci_inventory import load_config  # noqa: E402

import oci  # noqa: E402


def main():
    run = "--run" in sys.argv
    config = load_config()
    tenancy = config["tenancy"]
    compartment = os.environ.get("TF_VAR_compartment_ocid", tenancy)
    service = os.environ.get("TF_VAR_service", os.environ.get("TIN_SERVICE_NAME", "gateway"))
    environment = os.environ.get("TF_VAR_environment", os.environ.get("TIN_SERVICE_ENVIRONMENT", "prod"))

    compute = oci.core.ComputeClient(config)
    net = oci.core.VirtualNetworkClient(config)

    running = [i for i in compute.list_instances(compartment).data if i.lifecycle_state == "RUNNING"]
    tagged = [i for i in running if (i.freeform_tags or {}).get("service") == service
              and (i.freeform_tags or {}).get("environment") == environment]
    candidates = tagged or running
    if len(candidates) != 1:
        print(f"expected exactly one instance, found {len(candidates)}: {[i.display_name for i in candidates]}")
        return 1
    inst = candidates[0]
    vnic = compute.list_vnic_attachments(compartment, instance_id=inst.id).data[0]
    subnet = net.get_subnet(vnic.subnet_id).data
    vcn = net.get_vcn(subnet.vcn_id).data
    igw = [g for g in net.list_internet_gateways(compartment, vcn_id=vcn.id).data if g.lifecycle_state == "AVAILABLE"][0]

    imports = [
        ("oci_core_vcn.gateway_vcn", vcn.id),
        ("oci_core_internet_gateway.gateway_igw", igw.id),
        ("oci_core_default_route_table.gateway_rt", vcn.default_route_table_id),
        ("oci_core_default_security_list.gateway_sl", vcn.default_security_list_id),
        ("oci_core_subnet.gateway_subnet", subnet.id),
        ("oci_core_instance.gateway_instance", inst.id),
    ]
    tf_dir = Path(__file__).resolve().parent.parent / "terraform"
    for addr, ocid in imports:
        cmd = ["terraform", "import", "-input=false", addr, ocid]
        print(" ".join(cmd))
        if run:
            subprocess.run(cmd, cwd=tf_dir, check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
