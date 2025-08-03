def main():
    import oci
    from datetime import datetime
    import time
    import logging
    import sys

    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        handlers=[
            logging.StreamHandler(sys.stdout)
        ]
    )
    logger = logging.getLogger(__name__)

    # Create a default config using DEFAULT profile in default location
    config = oci.config.from_file()

    # Initialize service client with default config file
    resource_manager_client = oci.resource_manager.ResourceManagerClient(config)

    attempt = 0
    while True:
        attempt += 1
        
        # Step 1: Create the job
        logger.info(f"{'='*60}")
        logger.info(f"Attempt #{attempt} - Creating APPLY job at {datetime.now()}")
        logger.info(f"{'='*60}")
        
        create_job_response = resource_manager_client.create_job(
            create_job_details=oci.resource_manager.models.CreateJobDetails(
                stack_id="ocid1.ormstack.oc1.uk-london-1.amaaaaaa6arv52ia4luicwemi22lrslwvtfzllcj3zuzap7a432dkqt4qokq",
                display_name=f"api_job_{datetime.now().strftime("%Y%m%d%f")}",
                operation="APPLY",
                apply_job_plan_resolution=oci.resource_manager.models.ApplyJobPlanResolution(
                    is_auto_approved=True
                )
            )
        )
        
        job_id = create_job_response.data.id
        logger.info(f"Job created with ID: {job_id}")
        logger.info(f"Initial status: {create_job_response.data.lifecycle_state}")
        
        # Step 2: Wait for job to complete (check every minute)
        terminal_states = ["SUCCEEDED", "FAILED", "CANCELED"]
        
        while True:
            # Wait 60 seconds before checking
            logger.info("Waiting 60 seconds before checking status...")
            time.sleep(60)
            
            # Get current job status
            get_job_response = resource_manager_client.get_job(job_id=job_id)
            current_status = get_job_response.data.lifecycle_state
            
            logger.info(f"Job status: {current_status}")
            
            # Check if job has reached a terminal state
            if current_status in terminal_states:
                # Step 3 & 4: Handle terminal states
                if current_status == "FAILED":
                    failure_message = "Unknown error"
                    if get_job_response.data.failure_details:
                        failure_message = get_job_response.data.failure_details.message
                    
                    logger.error(f"❌ Job FAILED: {failure_message}")
                    
                    # Get job logs and extract [INFO] Error: messages
                    try:
                        logger.info("Fetching job logs for error details...")
                        logs_response = resource_manager_client.get_job_logs_content(job_id=job_id)
                        
                        # Check if data is bytes or string
                        if isinstance(logs_response.data, bytes):
                            logs_content = logs_response.data.decode('utf-8')
                        else:
                            logs_content = logs_response.data
                        
                        # Find all lines containing [INFO] Error:
                        error_lines = [line.strip() for line in logs_content.split('\n') 
                                     if '[INFO] Error:' in line]
                        
                        if error_lines:
                            logger.error("Error details from logs:")
                            for error_line in error_lines:
                                logger.error(f"  {error_line}")
                        else:
                            logger.warning("No [INFO] Error: messages found in logs")
                    except Exception as e:
                        logger.exception(f"Failed to retrieve job logs: {e}")
                    
                    break  # Exit inner loop, continue outer loop
                
                elif current_status == "SUCCEEDED":
                    logger.info(f"✅ Job SUCCEEDED! Exiting...")
                    logger.info(f"Job details: {get_job_response.data}")
                    return  # Exit the entire function
                
                elif current_status == "CANCELED":
                    logger.warning(f"⚠️  Job CANCELED! Exiting...")
                    logger.info(f"Job details: {get_job_response.data}")
                    return  # Exit the entire function


if __name__ == "__main__":
    main()
