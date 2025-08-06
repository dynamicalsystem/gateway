#!/usr/bin/env python3
"""
Clean up orphaned VCNs and their associated resources in OCI.
This script will delete VCNs named 'gateway-vcn' that have no running instances.
"""

import os
import sys
import time
import logging
from pathlib import Path

try:
    import oci
except ImportError:
    print("Error: OCI SDK not installed. Install with: pip install oci")
    sys.exit(1)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def get_oci_config():
    """Get OCI configuration from environment variables or config file"""
    # Try environment variables first (matching Terraform variables)
    if all(os.environ.get(var) for var in [
        'TF_VAR_tenancy_ocid',
        'TF_VAR_user_ocid',
        'TF_VAR_fingerprint',
        'TF_VAR_region',
        'TF_VAR_compartment_id'
    ]):
        # Check for private key path
        private_key_path = os.environ.get('TF_VAR_private_key_path')
        if not private_key_path:
            private_key_path = os.environ.get('OCI_PRIVATE_API_KEY', '/secrets/oci_api_key.pem')
        
        if not Path(private_key_path).exists():
            logger.error(f"Private key not found at: {private_key_path}")
            sys.exit(1)
        
        with open(private_key_path, 'r') as f:
            private_key = f.read()
        
        config = {
            'user': os.environ['TF_VAR_user_ocid'],
            'key_content': private_key,
            'fingerprint': os.environ['TF_VAR_fingerprint'],
            'tenancy': os.environ['TF_VAR_tenancy_ocid'],
            'region': os.environ['TF_VAR_region']
        }
        compartment_id = os.environ['TF_VAR_compartment_id']
        logger.info("Using OCI configuration from environment variables")
        return config, compartment_id
    else:
        # Try default OCI config file
        try:
            config = oci.config.from_file()
            compartment_id = config.get('compartment_id')
            if not compartment_id:
                logger.error("compartment_id not found in config file")
                sys.exit(1)
            logger.info("Using OCI configuration from ~/.oci/config")
            return config, compartment_id
        except Exception as e:
            logger.error(f"Failed to load OCI config: {e}")
            logger.error("Please set environment variables or configure ~/.oci/config")
            sys.exit(1)


def delete_vcn_resources(config, compartment_id, vcn_id, vcn_name):
    """Delete all resources associated with a VCN"""
    logger.info(f"Processing VCN: {vcn_name} ({vcn_id})")
    
    # Initialize clients
    network_client = oci.core.VirtualNetworkClient(config)
    compute_client = oci.core.ComputeClient(config)
    
    deleted_resources = []
    
    try:
        # 1. Check for and terminate any instances
        logger.info("  Checking for instances...")
        instances = compute_client.list_instances(
            compartment_id=compartment_id
        ).data
        
        for instance in instances:
            # Check if instance is in this VCN
            vnics = compute_client.list_vnic_attachments(
                compartment_id=compartment_id,
                instance_id=instance.id
            ).data
            
            for vnic_attachment in vnics:
                if vnic_attachment.subnet_id:
                    # Get subnet details to check VCN
                    try:
                        subnet = network_client.get_subnet(vnic_attachment.subnet_id).data
                        if subnet.vcn_id == vcn_id:
                            if instance.lifecycle_state != "TERMINATED":
                                logger.warning(f"  Found instance {instance.display_name} in VCN - skipping VCN deletion")
                                return False
                    except:
                        pass
        
        # 2. Delete subnets
        logger.info("  Deleting subnets...")
        subnets = network_client.list_subnets(
            compartment_id=compartment_id,
            vcn_id=vcn_id
        ).data
        
        for subnet in subnets:
            if subnet.lifecycle_state != "TERMINATED":
                try:
                    network_client.delete_subnet(subnet.id)
                    logger.info(f"    Deleted subnet: {subnet.display_name}")
                    deleted_resources.append(f"subnet:{subnet.display_name}")
                except Exception as e:
                    logger.error(f"    Failed to delete subnet {subnet.display_name}: {e}")
        
        # 3. Delete route tables (except default)
        logger.info("  Deleting route tables...")
        route_tables = network_client.list_route_tables(
            compartment_id=compartment_id,
            vcn_id=vcn_id
        ).data
        
        for rt in route_tables:
            if rt.lifecycle_state != "TERMINATED" and not rt.display_name.startswith("Default"):
                try:
                    network_client.delete_route_table(rt.id)
                    logger.info(f"    Deleted route table: {rt.display_name}")
                    deleted_resources.append(f"route_table:{rt.display_name}")
                except Exception as e:
                    logger.error(f"    Failed to delete route table {rt.display_name}: {e}")
        
        # 4. Delete security lists (except default)
        logger.info("  Deleting security lists...")
        security_lists = network_client.list_security_lists(
            compartment_id=compartment_id,
            vcn_id=vcn_id
        ).data
        
        for sl in security_lists:
            if sl.lifecycle_state != "TERMINATED" and not sl.display_name.startswith("Default"):
                try:
                    network_client.delete_security_list(sl.id)
                    logger.info(f"    Deleted security list: {sl.display_name}")
                    deleted_resources.append(f"security_list:{sl.display_name}")
                except Exception as e:
                    logger.error(f"    Failed to delete security list {sl.display_name}: {e}")
        
        # 5. Delete internet gateways
        logger.info("  Deleting internet gateways...")
        igws = network_client.list_internet_gateways(
            compartment_id=compartment_id,
            vcn_id=vcn_id
        ).data
        
        for igw in igws:
            if igw.lifecycle_state != "TERMINATED":
                try:
                    network_client.delete_internet_gateway(igw.id)
                    logger.info(f"    Deleted internet gateway: {igw.display_name}")
                    deleted_resources.append(f"igw:{igw.display_name}")
                except Exception as e:
                    logger.error(f"    Failed to delete internet gateway {igw.display_name}: {e}")
        
        # 6. Delete NAT gateways
        logger.info("  Deleting NAT gateways...")
        nat_gws = network_client.list_nat_gateways(
            compartment_id=compartment_id,
            vcn_id=vcn_id
        ).data
        
        for nat in nat_gws:
            if nat.lifecycle_state != "TERMINATED":
                try:
                    network_client.delete_nat_gateway(nat.id)
                    logger.info(f"    Deleted NAT gateway: {nat.display_name}")
                    deleted_resources.append(f"nat:{nat.display_name}")
                except Exception as e:
                    logger.error(f"    Failed to delete NAT gateway {nat.display_name}: {e}")
        
        # 7. Delete service gateways
        logger.info("  Deleting service gateways...")
        sgws = network_client.list_service_gateways(
            compartment_id=compartment_id,
            vcn_id=vcn_id
        ).data
        
        for sgw in sgws:
            if sgw.lifecycle_state != "TERMINATED":
                try:
                    network_client.delete_service_gateway(sgw.id)
                    logger.info(f"    Deleted service gateway: {sgw.display_name}")
                    deleted_resources.append(f"sgw:{sgw.display_name}")
                except Exception as e:
                    logger.error(f"    Failed to delete service gateway {sgw.display_name}: {e}")
        
        # Wait a moment for resources to be fully deleted
        if deleted_resources:
            logger.info("  Waiting for resources to be deleted...")
            time.sleep(5)
        
        # 8. Finally, delete the VCN
        logger.info(f"  Deleting VCN: {vcn_name}")
        try:
            network_client.delete_vcn(vcn_id)
            logger.info(f"  ✅ Successfully deleted VCN: {vcn_name}")
            return True
        except Exception as e:
            logger.error(f"  ❌ Failed to delete VCN {vcn_name}: {e}")
            return False
            
    except Exception as e:
        logger.error(f"Error processing VCN {vcn_name}: {e}")
        return False


def main():
    """Main cleanup function"""
    # Get OCI configuration
    config, compartment_id = get_oci_config()
    
    # Initialize VCN client
    network_client = oci.core.VirtualNetworkClient(config)
    
    # List all VCNs
    logger.info(f"Searching for VCNs in compartment: {compartment_id}")
    try:
        vcns = network_client.list_vcns(compartment_id=compartment_id).data
    except Exception as e:
        logger.error(f"Failed to list VCNs: {e}")
        sys.exit(1)
    
    # Filter for gateway-vcn VCNs
    main_vcns = [v for v in vcns if v.display_name == "gateway-vcn" and v.lifecycle_state == "AVAILABLE"]
    
    if not main_vcns:
        logger.info("No 'gateway-vcn' VCNs found to clean up")
        return
    
    logger.info(f"Found {len(main_vcns)} VCN(s) named 'gateway-vcn'")
    
    # Confirm before proceeding
    print(f"\n⚠️  WARNING: This will delete {len(main_vcns)} VCN(s) and all their resources!")
    print("VCNs to be deleted:")
    for vcn in main_vcns:
        print(f"  - {vcn.display_name} (ID: {vcn.id})")
    
    response = input("\nDo you want to proceed? (yes/no): ")
    if response.lower() != "yes":
        logger.info("Cleanup cancelled by user")
        return
    
    # Process each VCN
    deleted_count = 0
    failed_count = 0
    
    for vcn in main_vcns:
        if delete_vcn_resources(config, compartment_id, vcn.id, vcn.display_name):
            deleted_count += 1
        else:
            failed_count += 1
        
        # Small delay between VCNs
        time.sleep(2)
    
    # Summary
    logger.info("\n" + "="*60)
    logger.info(f"Cleanup complete:")
    logger.info(f"  - Successfully deleted: {deleted_count} VCN(s)")
    logger.info(f"  - Failed/Skipped: {failed_count} VCN(s)")
    
    if failed_count > 0:
        logger.warning("Some VCNs could not be deleted. They may have running instances.")
        logger.warning("Check the OCI console for remaining resources.")


if __name__ == "__main__":
    main()