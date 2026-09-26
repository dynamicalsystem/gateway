#!/usr/bin/env python3
"""Read-only inventory of compute and storage in the tenancy.

Lists instances, boot volumes, block volumes, attachments and backups across
every availability domain and compartment, then exits non-zero if anything
looks like an orphan:

  - a boot or block volume that is not attached to an instance
  - an instance without a managed-by freeform tag
  - a volume without Oracle's Always Free marker (system tag
    orcl-cloud.free-tier-retained) while the tenancy is inside the 200 GB
    allowance. Such a volume is billed at paid rates and Oracle's automatic
    transition to free has not fired; it needs a support request.

Credentials come from TF_VAR_* environment variables (as in the deploy
container) or fall back to ~/.oci/config.
"""

import os
import sys
from pathlib import Path

import oci

FREE_ALLOWANCE_GB = 200


def is_free_tier(volume):
    """True if Oracle has marked the volume as Always Free."""
    return (volume.system_tags or {}).get("orcl-cloud", {}).get("free-tier-retained") == "true"


def classify(instances, boot_volumes, block_volumes, attached_boot, attached_block,
             allowance_gb=FREE_ALLOWANCE_GB):
    """Decide what is wrong with a tenancy's compute and storage.

    Pure: takes lists of objects with the attributes the OCI SDK models
    expose (display_name, id, size_in_gbs, freeform_tags, system_tags) and
    dicts of volume id to instance id for attachments. Returns
    (problems, notes, total_gb). problems fail the run; notes are printed.
    """
    problems, notes, unmarked = [], [], []
    for i in instances:
        if not (i.freeform_tags or {}).get("managed-by"):
            problems.append(f"instance {i.display_name} has no managed-by tag")
    total_gb = 0
    for kind, volumes, attached in (("boot volume", boot_volumes, attached_boot),
                                    ("block volume", block_volumes, attached_block)):
        for v in volumes:
            total_gb += v.size_in_gbs
            if not attached.get(v.id):
                problems.append(f"{kind} {v.display_name} ({v.size_in_gbs} GB) is not attached")
            if not is_free_tier(v):
                unmarked.append(f"{kind} {v.display_name} ({v.size_in_gbs} GB)")
    if total_gb > allowance_gb:
        problems.append(f"total volume storage {total_gb} GB exceeds the {allowance_gb} GB allowance")
        notes.extend(f"{u} is billed at paid rates, expected while over the allowance" for u in unmarked)
    else:
        problems.extend(f"{u} has no free-tier-retained tag while the tenancy is inside the allowance: "
                        "it is being billed and Oracle's automatic transition has not fired; raise a support request"
                        for u in unmarked)
    return problems, notes, total_gb


def load_config():
    env = {k: os.environ.get(f"TF_VAR_{k}") for k in ("tenancy_ocid", "user_ocid", "fingerprint", "region")}
    if all(env.values()):
        key_path = os.environ.get("TF_VAR_private_key_path") or os.environ.get("OCI_PRIVATE_API_KEY", "/secrets/oci_api_key.pem")
        config = {
            "tenancy": env["tenancy_ocid"],
            "user": env["user_ocid"],
            "fingerprint": env["fingerprint"],
            "region": env["region"],
            "key_content": Path(key_path).read_text(),
        }
    else:
        config = oci.config.from_file()
    oci.config.validate_config(config)
    return config


def all_results(fn, *args, **kwargs):
    return oci.pagination.list_call_get_all_results(fn, *args, **kwargs).data


def main():
    config = load_config()
    tenancy = config["tenancy"]
    identity = oci.identity.IdentityClient(config)
    compute = oci.core.ComputeClient(config)
    blockstorage = oci.core.BlockstorageClient(config)

    compartments = [tenancy] + [
        c.id for c in all_results(identity.list_compartments, tenancy,
                                  compartment_id_in_subtree=True, access_level="ACCESSIBLE")
        if c.lifecycle_state == "ACTIVE"
    ]
    ads = [a.name for a in identity.list_availability_domains(tenancy).data]

    instances, boot_volumes, block_volumes = [], [], []
    attached_boot, attached_block = {}, {}

    print("=== INSTANCES ===")
    for c in compartments:
        for i in all_results(compute.list_instances, c):
            if i.lifecycle_state == "TERMINATED":
                continue
            instances.append(i)
            print(f"{i.lifecycle_state:11} {i.display_name:30} {i.shape:20} {i.time_created:%Y-%m-%d} "
                  f"managed-by={(i.freeform_tags or {}).get('managed-by')} {i.id}")
        for ad in ads:
            for ba in all_results(compute.list_boot_volume_attachments, ad, c):
                if ba.lifecycle_state in ("ATTACHED", "ATTACHING"):
                    attached_boot[ba.boot_volume_id] = ba.instance_id
        for va in all_results(compute.list_volume_attachments, c):
            if va.lifecycle_state in ("ATTACHED", "ATTACHING"):
                attached_block[va.volume_id] = va.instance_id

    print("\n=== BOOT VOLUMES ===")
    for c in compartments:
        for ad in ads:
            for bv in all_results(blockstorage.list_boot_volumes, availability_domain=ad, compartment_id=c):
                if bv.lifecycle_state == "TERMINATED":
                    continue
                boot_volumes.append(bv)
                print(f"{bv.lifecycle_state:10} {bv.size_in_gbs:5}GB vpus={bv.vpus_per_gb:3} {bv.time_created:%Y-%m-%d} "
                      f"{bv.display_name:45} attached={attached_boot.get(bv.id) or 'NO'} free-tier={'yes' if is_free_tier(bv) else 'NO'}")

    print("\n=== BLOCK VOLUMES ===")
    for c in compartments:
        for v in all_results(blockstorage.list_volumes, compartment_id=c):
            if v.lifecycle_state == "TERMINATED":
                continue
            block_volumes.append(v)
            print(f"{v.lifecycle_state:10} {v.size_in_gbs:5}GB vpus={v.vpus_per_gb:3} {v.time_created:%Y-%m-%d} "
                  f"{v.display_name:45} attached={attached_block.get(v.id) or 'NO'} free-tier={'yes' if is_free_tier(v) else 'NO'}")

    print("\n=== VOLUME BACKUPS ===")
    for c in compartments:
        for b in all_results(blockstorage.list_boot_volume_backups, compartment_id=c):
            if b.lifecycle_state != "TERMINATED":
                print(f"boot-backup  {b.lifecycle_state:10} {b.unique_size_in_gbs}GB {b.time_created:%Y-%m-%d} {b.display_name}")
        for b in all_results(blockstorage.list_volume_backups, compartment_id=c):
            if b.lifecycle_state != "TERMINATED":
                print(f"block-backup {b.lifecycle_state:10} {b.unique_size_in_gbs}GB {b.time_created:%Y-%m-%d} {b.display_name}")

    problems, notes, total_gb = classify(instances, boot_volumes, block_volumes, attached_boot, attached_block)
    print(f"\nTOTAL live volume storage: {total_gb} GB (Always Free allowance is {FREE_ALLOWANCE_GB} GB)")
    for n in notes:
        print(f"  note: {n}")

    if problems:
        print("\nPROBLEMS:")
        for p in problems:
            print(f"  [x] {p}")
        return 1
    print("\n[/] no orphaned volumes, all instances tagged, all volumes marked Always Free")
    return 0


if __name__ == "__main__":
    sys.exit(main())
