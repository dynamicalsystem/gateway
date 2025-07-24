def main():
    import oci
    from datetime import datetime
    import time

    # Create a default config using DEFAULT profile in default location
    config = oci.config.from_file()

    # Initialize service client with default config file
    resource_manager_client = oci.resource_manager.ResourceManagerClient(config)

    attempt = 0
    while True:
        attempt += 1
        
        # Step 1: Create the job
        print(f"\n{'='*60}")
        print(f"Attempt #{attempt} - Creating APPLY job at {datetime.now()}")
        print(f"{'='*60}")
        
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
        print(f"Job created with ID: {job_id}")
        print(f"Initial status: {create_job_response.data.lifecycle_state}")
        
        # Step 2: Wait for job to complete (check every minute)
        terminal_states = ["SUCCEEDED", "FAILED", "CANCELED"]
        
        while True:
            # Wait 60 seconds before checking
            print("\nWaiting 60 seconds before checking status...")
            time.sleep(60)
            
            # Get current job status
            get_job_response = resource_manager_client.get_job(job_id=job_id)
            current_status = get_job_response.data.lifecycle_state
            
            print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Job status: {current_status}")
            
            # Check if job has reached a terminal state
            if current_status in terminal_states:
                # Step 3 & 4: Handle terminal states
                if current_status == "FAILED":
                    failure_message = "Unknown error"
                    if get_job_response.data.failure_details:
                        failure_message = get_job_response.data.failure_details.message
                    
                    print(f"\n❌ Job FAILED: {failure_message}")
                    
                    # Get job logs and extract [INFO] Error: messages
                    try:
                        print("\nFetching job logs for error details...")
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
                            print("\nError details from logs:")
                            for error_line in error_lines:
                                print(f"  {error_line}")
                        else:
                            print("No [INFO] Error: messages found in logs")
                    except Exception as e:
                        print(f"Failed to retrieve job logs: {e}")
                    
                    break  # Exit inner loop, continue outer loop
                
                elif current_status == "SUCCEEDED":
                    print(f"\n✅ Job SUCCEEDED! Exiting...")
                    print(get_job_response.data)
                    return  # Exit the entire function
                
                elif current_status == "CANCELED":
                    print(f"\n⚠️  Job CANCELED! Exiting...")
                    print(get_job_response.data)
                    return  # Exit the entire function


if __name__ == "__main__":
    main()
