#!/usr/bin/env python3
"""
Worker System for Orpheus-FastAPI
Handles authentication, narration retrieval, TTS generation, S3 upload, and API updates
"""

import asyncio
import aiohttp
import json
import os
import time
import uuid
import wave
from datetime import datetime
from typing import Optional, Dict, Any
from dataclasses import dataclass
from dotenv import load_dotenv
import boto3
from botocore.exceptions import ClientError
import logging
from concurrent.futures import ThreadPoolExecutor
import threading

# Load environment variables
load_dotenv()

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

@dataclass
class WorkerConfig:
    """Configuration for the worker system"""
    # API Configuration
    api_base_url: str = os.getenv('API_BASE_URL', 'https://api.example.com')
    tts_server_url: str = os.getenv('TTS_SERVER_URL', 'http://localhost:5005')
    server_to_server_api_key: str = os.getenv('SERVER_TO_SERVER_API_KEY', '')
    
    # TTS Configuration
    voice: str = "tara"
    
    # S3 Configuration
    aws_access_key_id: str = os.getenv('AWS_ACCESS_KEY_ID', '')
    aws_secret_access_key: str = os.getenv('AWS_SECRET_ACCESS_KEY', '')
    aws_region: str = os.getenv('AWS_REGION', 'us-east-1')
    s3_bucket: str = os.getenv('S3_BUCKET', '')
    
    # Worker Configuration
    max_workers: int = int(os.getenv('MAX_WORKERS', '3'))
    worker_timeout: int = int(os.getenv('WORKER_TIMEOUT', '300'))  # 5 minutes
    retry_attempts: int = int(os.getenv('RETRY_ATTEMPTS', '3'))
    retry_delay: int = int(os.getenv('RETRY_DELAY', '5'))  # seconds

class WorkerError(Exception):
    """Custom exception for worker errors"""
    pass

class AudioProcessor:
    """Handles audio file processing and duration calculation"""
    
    @staticmethod
    def get_audio_duration(file_path: str) -> float:
        """Get duration of audio file in seconds"""
        try:
            with wave.open(file_path, 'rb') as wav_file:
                frames = wav_file.getnframes()
                sample_rate = wav_file.getframerate()
                duration = frames / float(sample_rate)
                return round(duration, 2)
        except Exception as e:
            logger.error(f"Error getting audio duration: {e}")
            return 0.0

class S3Uploader:
    """Handles S3 upload operations"""
    
    def __init__(self, config: WorkerConfig):
        self.config = config
        self.s3_client = None
        self._initialize_s3_client()
    
    def _initialize_s3_client(self):
        """Initialize S3 client with credentials"""
        try:
            self.s3_client = boto3.client(
                's3',
                aws_access_key_id=self.config.aws_access_key_id,
                aws_secret_access_key=self.config.aws_secret_access_key,
                region_name=self.config.aws_region
            )
            logger.info("S3 client initialized successfully")
        except Exception as e:
            logger.error(f"Failed to initialize S3 client: {e}")
            raise WorkerError(f"S3 initialization failed: {e}")
    
    async def upload_audio(self, file_path: str, narration_id: str) -> str:
        """Upload audio file to S3 and return URL"""
        if not self.s3_client:
            raise WorkerError("S3 client not initialized")
        
        try:
            # Generate unique S3 key
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            s3_key = f"narrations/{narration_id}/audio_{timestamp}.wav"
            
            # Upload file
            loop = asyncio.get_event_loop()
            with ThreadPoolExecutor() as executor:
                await loop.run_in_executor(
                    executor,
                    self.s3_client.upload_file,
                    file_path,
                    self.config.s3_bucket,
                    s3_key,
                    {'ContentType': 'audio/wav'}
                )
            
            # Generate URL
            audio_url = f"https://{self.config.s3_bucket}.s3.{self.config.aws_region}.amazonaws.com/{s3_key}"
            logger.info(f"Audio uploaded successfully: {audio_url}")
            return audio_url
            
        except ClientError as e:
            logger.error(f"S3 upload failed: {e}")
            raise WorkerError(f"S3 upload failed: {e}")
        except Exception as e:
            logger.error(f"Unexpected error during S3 upload: {e}")
            raise WorkerError(f"S3 upload error: {e}")

class APIClient:
    """Handles all API communications"""
    
    def __init__(self, config: WorkerConfig):
        self.config = config
        self.session = None
    
    async def __aenter__(self):
        """Async context manager entry"""
        self.session = aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=self.config.worker_timeout)
        )
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit"""
        if self.session:
            await self.session.close()
    
    
    async def get_narration(self) -> Dict[str, Any]:
        """Get narration for audio generation"""
        if not self.config.server_to_server_api_key:
            raise WorkerError("No server-to-server API key available")
        
        url = f"{self.config.api_base_url}/twin/narrations/audio/"
        headers = {"X-API-Key": self.config.server_to_server_api_key}
        
        async with self.session.get(url, headers=headers) as response:
            if response.status == 404:
                raise WorkerError("No narration available for audio generation")
            elif response.status != 200:
                try:
                    error_content = await response.text()
                    logger.error(f"Get Narration API Error - Status: {response.status}, Response: {error_content}")
                    raise WorkerError(f"Get narration failed with status {response.status}: {error_content}")
                except Exception as e:
                    logger.error(f"Get narration failed with status {response.status}, could not read response: {e}")
                    raise WorkerError(f"Get narration failed with status {response.status}")
            
            data = await response.json()
            logger.info(f"Narration retrieved for narration ID: {data.get('id')}")
            return data
    
    async def generate_tts(self, text: str) -> str:
        """Generate TTS audio and return file path"""
        url = f"{self.config.tts_server_url}/v1/audio/speech"
        payload = {
            "input": text,
            "model": "orpheus",
            "voice": self.config.voice,
            "response_format": "wav",
            "speed": 1.0
        }
        
        async with self.session.post(url, json=payload) as response:
            if response.status != 200:
                try:
                    error_content = await response.text()
                    logger.error(f"TTS API Error - Status: {response.status}, Response: {error_content}")
                    raise WorkerError(f"TTS generation failed with status {response.status}: {error_content}")
                except Exception as e:
                    logger.error(f"TTS generation failed with status {response.status}, could not read response: {e}")
                    raise WorkerError(f"TTS generation failed with status {response.status}")
            
            # Generate unique filename
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            worker_id = threading.current_thread().ident
            filename = f"worker_{worker_id}_{timestamp}.wav"
            file_path = os.path.join("outputs", filename)
            
            # Ensure outputs directory exists
            os.makedirs("outputs", exist_ok=True)
            
            # Save audio file
            with open(file_path, 'wb') as f:
                async for chunk in response.content.iter_chunked(8192):
                    f.write(chunk)
            
            logger.info(f"TTS audio generated: {file_path}")
            return file_path
    
    async def update_narration_audio(self, narration_id: str, audio_url: str, duration: float) -> Dict[str, Any]:
        """Update narration with audio information"""
        if not self.config.server_to_server_api_key:
            raise WorkerError("No server-to-server API key available")
        
        url = f"{self.config.api_base_url}/twin/narrations/{narration_id}/audio/"
        headers = {"X-API-Key": self.config.server_to_server_api_key}
        payload = {
            "audio_file_url": audio_url,
            "audio_duration": int(duration)
        }
        
        async with self.session.post(url, json=payload, headers=headers) as response:
            if response.status == 404:
                raise WorkerError("Narration not found")
            elif response.status != 200:
                try:
                    error_content = await response.text()
                    logger.error(f"Update Narration API Error - Status: {response.status}, Response: {error_content}")
                    raise WorkerError(f"Update narration failed with status {response.status}: {error_content}")
                except Exception as e:
                    logger.error(f"Update narration failed with status {response.status}, could not read response: {e}")
                    raise WorkerError(f"Update narration failed with status {response.status}")
            
            data = await response.json()
            logger.info(f"Narration updated successfully: {narration_id}")
            return data

class Worker:
    """Individual worker that processes a single narration"""
    
    def __init__(self, worker_id: int, config: WorkerConfig):
        self.worker_id = worker_id
        self.config = config
        self.s3_uploader = S3Uploader(config)
        self.audio_processor = AudioProcessor()
    
    async def process_narration(self) -> bool:
        """Process a single narration through the complete pipeline"""
        logger.info(f"Worker {self.worker_id} starting narration processing")
        
        try:
            async with APIClient(self.config) as api_client:
                # Step 1: Get narration
                logger.info(f"Worker {self.worker_id}: Getting narration")
                narration_data = await api_client.get_narration()
                
                narration_id = narration_data.get('id')
                if not narration_id:
                    raise WorkerError("No narration ID in narration data")
                
                # Extract text for TTS (combine research data)
                company_research = narration_data.get('company_deep_research', '')
                profile_research = narration_data.get('profile_deep_research', '')
                text_content = f"{company_research}\n\n{profile_research}".strip()
                
                if not text_content:
                    raise WorkerError("No text content available for TTS")
                
                # Step 2: Generate TTS audio
                logger.info(f"Worker {self.worker_id}: Generating TTS audio")
                audio_file_path = await api_client.generate_tts(text_content)
                
                # Step 3: Get audio duration
                logger.info(f"Worker {self.worker_id}: Calculating audio duration")
                audio_duration = self.audio_processor.get_audio_duration(audio_file_path)
                
                # Step 4: Upload to S3
                logger.info(f"Worker {self.worker_id}: Uploading to S3")
                audio_url = await self.s3_uploader.upload_audio(audio_file_path, narration_id)
                
                # Step 5: Update narration with audio info
                logger.info(f"Worker {self.worker_id}: Updating narration")
                await api_client.update_narration_audio(narration_id, audio_url, audio_duration)
                
                # Cleanup local file
                try:
                    os.remove(audio_file_path)
                    logger.info(f"Worker {self.worker_id}: Cleaned up local file")
                except Exception as e:
                    logger.warning(f"Worker {self.worker_id}: Failed to cleanup file: {e}")
                
                logger.info(f"Worker {self.worker_id}: Successfully processed narration {narration_id}")
                return True
                
        except Exception as e:
            logger.error(f"Worker {self.worker_id}: Error processing narration: {e}")
            return False

class WorkerManager:
    """Manages multiple workers and handles the worker lifecycle"""
    
    def __init__(self, config: WorkerConfig):
        self.config = config
        self.active_workers = set()
        self.worker_counter = 0
        self.running = False
    
    async def start_worker(self) -> None:
        """Start a single worker"""
        self.worker_counter += 1
        worker_id = self.worker_counter
        
        if worker_id in self.active_workers:
            return
        
        self.active_workers.add(worker_id)
        
        try:
            worker = Worker(worker_id, self.config)
            
            # Process with retry logic
            for attempt in range(self.config.retry_attempts):
                try:
                    success = await worker.process_narration()
                    if success:
                        break
                    else:
                        logger.warning(f"Worker {worker_id}: Attempt {attempt + 1} failed")
                        if attempt < self.config.retry_attempts - 1:
                            await asyncio.sleep(self.config.retry_delay)
                except Exception as e:
                    logger.error(f"Worker {worker_id}: Attempt {attempt + 1} error: {e}")
                    if attempt < self.config.retry_attempts - 1:
                        await asyncio.sleep(self.config.retry_delay)
            
        except Exception as e:
            logger.error(f"Worker {worker_id}: Fatal error: {e}")
        finally:
            self.active_workers.discard(worker_id)
            logger.info(f"Worker {worker_id}: Finished")
    
    async def run(self) -> None:
        """Run the worker system continuously"""
        logger.info(f"Starting worker system with {self.config.max_workers} max workers")
        self.running = True
        
        try:
            while self.running:
                # Start new workers if we're below the limit
                if len(self.active_workers) < self.config.max_workers:
                    asyncio.create_task(self.start_worker())
                
                # Wait a bit before checking again
                await asyncio.sleep(1)
                
        except KeyboardInterrupt:
            logger.info("Received interrupt signal, shutting down...")
        finally:
            self.running = False
            
            # Wait for active workers to finish
            if self.active_workers:
                logger.info(f"Waiting for {len(self.active_workers)} active workers to finish...")
                while self.active_workers:
                    await asyncio.sleep(1)
            
            logger.info("Worker system shutdown complete")
    
    def stop(self):
        """Stop the worker system"""
        self.running = False

async def main():
    """Main entry point"""
    # Load configuration
    config = WorkerConfig()
    
    # Validate configuration
    required_env_vars = [
        'API_BASE_URL', 'SERVER_TO_SERVER_API_KEY', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'S3_BUCKET'
    ]
    
    missing_vars = []
    for var in required_env_vars:
        if not getattr(config, var.lower(), None):
            missing_vars.append(var)
    
    if missing_vars:
        logger.error(f"Missing required environment variables: {', '.join(missing_vars)}")
        logger.error("Please check your .env file")
        return
    
    # Create and run worker manager
    manager = WorkerManager(config)
    
    try:
        await manager.run()
    except Exception as e:
        logger.error(f"Worker system error: {e}")
    finally:
        manager.stop()

if __name__ == "__main__":
    asyncio.run(main())
