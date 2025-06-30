#!/usr/bin/env python3
"""
CLI script to run the worker system
"""

import argparse
import asyncio
import sys
import os
from worker_system import WorkerManager, WorkerConfig

def main():
    parser = argparse.ArgumentParser(description='Run the Orpheus Worker System')
    parser.add_argument('--workers', '-w', type=int, default=None,
                       help='Number of concurrent workers (overrides .env setting)')
    parser.add_argument('--api-url', type=str, default=None,
                       help='API base URL (overrides .env setting)')
    parser.add_argument('--tts-url', type=str, default=None,
                       help='TTS server URL (overrides .env setting)')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Enable verbose logging')
    
    args = parser.parse_args()
    
    # Load configuration
    config = WorkerConfig()
    
    # Override with command line arguments
    if args.workers:
        config.max_workers = args.workers
    if args.api_url:
        config.api_base_url = args.api_url
    if args.tts_url:
        config.tts_server_url = args.tts_url
    
    # Set logging level
    if args.verbose:
        import logging
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Validate required environment variables
    required_vars = [
        ('API_BASE_URL', config.api_base_url),
        ('AWS_ACCESS_KEY_ID', config.aws_access_key_id),
        ('AWS_SECRET_ACCESS_KEY', config.aws_secret_access_key),
        ('S3_BUCKET', config.s3_bucket)
    ]
    
    missing_vars = []
    for var_name, var_value in required_vars:
        if not var_value or var_value == 'your_aws_access_key_id' or var_value == 'your_aws_secret_access_key' or var_value == 'your-s3-bucket-name':
            missing_vars.append(var_name)
    
    if missing_vars:
        print("❌ Missing or invalid environment variables:")
        for var in missing_vars:
            print(f"   - {var}")
        print("\n📝 Please update your .env file with the correct values.")
        print("   Copy .env.example to .env and fill in your actual values.")
        sys.exit(1)
    
    print("🚀 Starting Orpheus Worker System")
    print(f"   Workers: {config.max_workers}")
    print(f"   API URL: {config.api_base_url}")
    print(f"   TTS URL: {config.tts_server_url}")
    print(f"   S3 Bucket: {config.s3_bucket}")
    print(f"   AWS Region: {config.aws_region}")
    print("\n⏹️  Press Ctrl+C to stop\n")
    
    # Create and run worker manager
    manager = WorkerManager(config)
    
    try:
        asyncio.run(manager.run())
    except KeyboardInterrupt:
        print("\n🛑 Shutting down worker system...")
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
