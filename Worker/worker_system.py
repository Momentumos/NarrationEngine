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
import random
import subprocess
import shutil
import platform
from datetime import datetime
from typing import Optional, Dict, Any
from dataclasses import dataclass
from dotenv import load_dotenv
import boto3
from botocore.exceptions import ClientError
import logging
from concurrent.futures import ThreadPoolExecutor
import threading

# Import pydub for audio conversion
try:
    from pydub import AudioSegment
    PYDUB_AVAILABLE = True
except ImportError:
    PYDUB_AVAILABLE = False
    logger.warning("pydub not available, MP3 conversion will use ffmpeg directly")

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
    use_random_voice: bool = os.getenv('USE_RANDOM_VOICE', 'true').lower() in ('true', '1', 'yes', 'on')
    
    # S3 Configuration
    aws_access_key_id: str = os.getenv('AWS_ACCESS_KEY_ID', '')
    aws_secret_access_key: str = os.getenv('AWS_SECRET_ACCESS_KEY', '')
    aws_region: str = os.getenv('AWS_REGION', 'us-east-1')
    s3_bucket: str = os.getenv('S3_BUCKET', '')
    
    # Discord Configuration
    discord_webhook_url: str = os.getenv('DISCORD_WEBHOOK_URL', '')
    
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
    
    @staticmethod
    def _check_ffmpeg_availability() -> bool:
        """Check if ffmpeg is available on the system"""
        try:
            result = subprocess.run(['ffmpeg', '-version'], 
                                  capture_output=True, text=True, timeout=10)
            return result.returncode == 0
        except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError):
            return False
    
    @staticmethod
    def _install_ffmpeg_instructions() -> str:
        """Return platform-specific ffmpeg installation instructions"""
        system = platform.system().lower()
        if system == 'darwin':  # macOS
            return "Install ffmpeg on macOS: brew install ffmpeg"
        elif system == 'linux':  # Ubuntu/Linux
            return "Install ffmpeg on Ubuntu/Linux: sudo apt update && sudo apt install ffmpeg"
        else:
            return "Install ffmpeg for your operating system"
    
    @staticmethod
    def convert_wav_to_mp3_pydub(wav_path: str, mp3_path: str) -> bool:
        """Convert WAV to MP3 using pydub (requires ffmpeg)"""
        try:
            if not PYDUB_AVAILABLE:
                logger.error("pydub is not available for MP3 conversion")
                return False
            
            # Load WAV file
            audio = AudioSegment.from_wav(wav_path)
            
            # Export as MP3
            audio.export(mp3_path, format="mp3", bitrate="128k")
            
            logger.info(f"Successfully converted {wav_path} to {mp3_path} using pydub")
            return True
            
        except Exception as e:
            logger.error(f"Error converting WAV to MP3 using pydub: {e}")
            return False
    
    @staticmethod
    def convert_wav_to_mp3_ffmpeg(wav_path: str, mp3_path: str) -> bool:
        """Convert WAV to MP3 using ffmpeg directly"""
        try:
            # Check if ffmpeg is available
            if not AudioProcessor._check_ffmpeg_availability():
                logger.error(f"ffmpeg is not available. {AudioProcessor._install_ffmpeg_instructions()}")
                return False
            
            # Run ffmpeg conversion
            cmd = [
                'ffmpeg',
                '-i', wav_path,           # Input file
                '-codec:a', 'libmp3lame', # MP3 encoder
                '-b:a', '128k',           # Bitrate
                '-y',                     # Overwrite output file
                mp3_path                  # Output file
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            
            if result.returncode == 0:
                logger.info(f"Successfully converted {wav_path} to {mp3_path} using ffmpeg")
                return True
            else:
                logger.error(f"ffmpeg conversion failed: {result.stderr}")
                return False
                
        except subprocess.TimeoutExpired:
            logger.error("ffmpeg conversion timed out")
            return False
        except Exception as e:
            logger.error(f"Error converting WAV to MP3 using ffmpeg: {e}")
            return False
    
    @staticmethod
    def convert_wav_to_mp3(wav_path: str) -> str:
        """
        Convert WAV file to MP3 format
        Returns the path to the MP3 file
        Tries pydub first, falls back to direct ffmpeg
        """
        if not os.path.exists(wav_path):
            raise WorkerError(f"WAV file not found: {wav_path}")
        
        # Generate MP3 file path
        mp3_path = wav_path.replace('.wav', '.mp3')
        
        # Try pydub first (more reliable)
        if PYDUB_AVAILABLE:
            if AudioProcessor.convert_wav_to_mp3_pydub(wav_path, mp3_path):
                return mp3_path
            else:
                logger.warning("pydub conversion failed, trying direct ffmpeg")
        
        # Fallback to direct ffmpeg
        if AudioProcessor.convert_wav_to_mp3_ffmpeg(wav_path, mp3_path):
            return mp3_path
        
        # If both methods fail, raise an error
        system = platform.system().lower()
        error_msg = f"Failed to convert WAV to MP3. {AudioProcessor._install_ffmpeg_instructions()}"
        logger.error(error_msg)
        raise WorkerError(error_msg)
    
    @staticmethod
    def get_mp3_duration(file_path: str) -> float:
        """Get duration of MP3 file in seconds using pydub or ffmpeg"""
        try:
            if PYDUB_AVAILABLE:
                # Use pydub if available
                audio = AudioSegment.from_mp3(file_path)
                duration = len(audio) / 1000.0  # Convert milliseconds to seconds
                return round(duration, 2)
            else:
                # Fallback to ffmpeg
                if AudioProcessor._check_ffmpeg_availability():
                    cmd = [
                        'ffmpeg',
                        '-i', file_path,
                        '-f', 'null',
                        '-'
                    ]
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                    
                    # Parse duration from ffmpeg output
                    for line in result.stderr.split('\n'):
                        if 'Duration:' in line:
                            duration_str = line.split('Duration:')[1].split(',')[0].strip()
                            # Parse HH:MM:SS.ss format
                            time_parts = duration_str.split(':')
                            if len(time_parts) == 3:
                                hours = float(time_parts[0])
                                minutes = float(time_parts[1])
                                seconds = float(time_parts[2])
                                total_seconds = hours * 3600 + minutes * 60 + seconds
                                return round(total_seconds, 2)
                
                # If we can't get duration, return 0
                logger.warning(f"Could not determine MP3 duration for {file_path}")
                return 0.0
                
        except Exception as e:
            logger.error(f"Error getting MP3 duration: {e}")
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
            # Determine file extension and content type
            file_extension = os.path.splitext(file_path)[1].lower()
            if file_extension == '.mp3':
                content_type = 'audio/mpeg'
                file_ext = 'mp3'
            elif file_extension == '.wav':
                content_type = 'audio/wav'
                file_ext = 'wav'
            else:
                # Default to MP3 if unknown
                content_type = 'audio/mpeg'
                file_ext = 'mp3'
            
            # Generate unique S3 key
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            s3_key = f"narrations/{narration_id}/audio_{timestamp}.{file_ext}"
            
            # Upload file
            loop = asyncio.get_event_loop()
            with ThreadPoolExecutor() as executor:
                await loop.run_in_executor(
                    executor,
                    self.s3_client.upload_file,
                    file_path,
                    self.config.s3_bucket,
                    s3_key,
                    {'ContentType': content_type}
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

class DiscordNotifier:
    """Handles Discord webhook notifications"""
    
    def __init__(self, config: WorkerConfig):
        self.config = config
        self.webhook_url = config.discord_webhook_url
    
    async def send_narration_summary(self, session: aiohttp.ClientSession, narration_data: Dict[str, Any], 
                                   audio_url: str, audio_duration: float, worker_id: int, generation_time: float = 0.0) -> None:
        """Send a summary of the processed narration to Discord"""
        if not self.webhook_url:
            logger.info("Discord webhook URL not configured, skipping notification")
            return
        
        temp_audio_file = None
        temp_text_file = None
        try:
            # Extract relevant information from narration data
            narration_id = narration_data.get('id', 'Unknown')
            full_text = narration_data.get('text', '')
            
            # If no text, try to get from research data
            if not full_text:
                company_research = narration_data.get('company_deep_research', '')
                profile_research = narration_data.get('profile_deep_research', '')
                full_text = f"{company_research}\n\n{profile_research}".strip()
            
            # Extract person's name and other details
            person_name = narration_data.get('name', narration_data.get('person_name', 'Unknown Person'))
            target_gender = narration_data.get('target_gender', 'Unknown')
            
            # Get the chosen voice (we need to determine this from the worker's voice selection)
            chosen_voice = VoiceSelector.get_voice(self.config, target_gender)
            
            # Format duration
            duration_minutes = int(audio_duration // 60)
            duration_seconds = int(audio_duration % 60)
            duration_str = f"{duration_minutes}m {duration_seconds}s" if duration_minutes > 0 else f"{duration_seconds}s"
            
            # Format generation time
            generation_time_str = f"{generation_time}s" if generation_time > 0 else "N/A"
            
            # Generate random color for the embed
            random_color = random.randint(0x000000, 0xFFFFFF)
            
            # Create Discord embed with person's name as title
            embed = {
                "title": person_name,
                "color": random_color,
                "fields": [
                    {
                        "name": "Details",
                        "value": f"**Narration ID:** `{narration_id}`\n**Gender:** {target_gender}\n**Chosen Voice:** {chosen_voice}\n**Audio Duration:** {duration_str}\n**Time to Generate:** {generation_time_str}",
                        "inline": False
                    }
                ],
                "timestamp": datetime.now().isoformat(),
                "footer": {
                    "text": "Orpheus Narration Engine"
                }
            }
            
            # Handle narration text - add it to the Details field or as separate field
            if full_text:
                # Check if adding the text to Details field would exceed Discord's limit
                current_details = embed["fields"][0]["value"]
                text_preview = full_text[:200] + "..." if len(full_text) > 200 else full_text
                
                # Try to add text to the Details field first
                details_with_text = f"{current_details}\n**Narration Text:** {text_preview}"
                
                if len(details_with_text) <= 1024:  # Discord field limit
                    # Update the Details field to include the text
                    embed["fields"][0]["value"] = details_with_text
                else:
                    # Add as separate field if it fits, otherwise use file attachment
                    if len(full_text) <= 900:  # Leave room for formatting
                        embed["fields"].append({
                            "name": "Narration Text",
                            "value": f"```{full_text}```",
                            "inline": False
                        })
                    else:
                        # Text is too long, use file attachment
                        embed["fields"].append({
                            "name": "Narration Text",
                            "value": "📄 Complete text attached as file (too long for embed)",
                            "inline": False
                        })
                        
                        # Create temporary text file
                        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                        temp_text_file = f"temp_discord_text_{narration_id}_{timestamp}.txt"
                        
                        # Ensure outputs directory exists
                        os.makedirs("outputs", exist_ok=True)
                        temp_text_path = os.path.join("outputs", temp_text_file)
                        
                        # Save text file
                        with open(temp_text_path, 'w', encoding='utf-8') as f:
                            f.write(f"Narration ID: {narration_id}\n")
                            f.write(f"Person: {person_name}\n")
                            f.write(f"Gender: {target_gender}\n")
                            f.write(f"Voice: {chosen_voice}\n")
                            f.write(f"Duration: {duration_str}\n")
                            f.write(f"Generation Time: {generation_time_str}\n")
                            f.write(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
                            f.write("=" * 50 + "\n\n")
                            f.write(full_text)
                        
                        logger.info(f"Created text file for Discord attachment: {temp_text_path}")
            
            # Download audio file for attachment
            logger.info(f"Downloading audio file from {audio_url} for Discord attachment")
            async with session.get(audio_url) as audio_response:
                if audio_response.status == 200:
                    # Create temporary file for the audio
                    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                    file_extension = '.mp3' if audio_url.endswith('.mp3') else '.wav'
                    temp_audio_file = f"temp_discord_audio_{narration_id}_{timestamp}{file_extension}"
                    
                    # Ensure outputs directory exists
                    os.makedirs("outputs", exist_ok=True)
                    temp_audio_path = os.path.join("outputs", temp_audio_file)
                    
                    # Save audio file temporarily
                    with open(temp_audio_path, 'wb') as f:
                        async for chunk in audio_response.content.iter_chunked(8192):
                            f.write(chunk)
                    
                    logger.info(f"Audio file downloaded for Discord attachment: {temp_audio_path}")
                    
                    # Prepare multipart form data for Discord webhook with file attachment(s)
                    data = aiohttp.FormData()
                    data.add_field('username', 'Narration Engine')
                    data.add_field('content', f'🎵 **New Narration Generated!**')
                    
                    # Add the embed as JSON
                    payload = {"embeds": [embed]}
                    data.add_field('payload_json', json.dumps(payload))
                    
                    # Add the audio file
                    audio_filename = f"narration_{narration_id}_audio{file_extension}"
                    with open(temp_audio_path, 'rb') as audio_file:
                        data.add_field('files[0]', audio_file.read(), 
                                     filename=audio_filename, 
                                     content_type='audio/mpeg' if file_extension == '.mp3' else 'audio/wav')
                    
                    # Add text file if it exists
                    if temp_text_file:
                        text_filename = f"narration_{narration_id}_text.txt"
                        with open(temp_text_path, 'rb') as text_file:
                            data.add_field('files[1]', text_file.read(),
                                         filename=text_filename,
                                         content_type='text/plain')
                    
                    # Send to Discord with file attachment(s)
                    async with session.post(self.webhook_url, data=data) as response:
                        if response.status == 200:
                            logger.info(f"Discord notification with attachments sent successfully for narration {narration_id}")
                        else:
                            error_text = await response.text()
                            logger.warning(f"Discord notification failed: {response.status} - {error_text}")
                
                else:
                    logger.warning(f"Failed to download audio file for Discord attachment: {audio_response.status}")
                    # Fallback to URL-only message
                    content = f"🎵 **Audio File**: {audio_url}"
                    payload = {
                        "username": "Narration Engine",
                        "content": content,
                        "embeds": [embed]
                    }
                    
                    async with session.post(self.webhook_url, json=payload) as response:
                        if response.status == 204:
                            logger.info(f"Discord notification sent successfully for narration {narration_id} (fallback)")
                        else:
                            error_text = await response.text()
                            logger.warning(f"Discord notification failed: {response.status} - {error_text}")
                    
        except Exception as e:
            logger.error(f"Error sending Discord notification: {e}")
        finally:
            # Clean up temporary Discord files - ensure all temp files are deleted after notification
            temp_files_cleaned = 0
            
            if temp_audio_file:
                temp_audio_path = os.path.join("outputs", temp_audio_file)
                try:
                    if os.path.exists(temp_audio_path):
                        os.remove(temp_audio_path)
                        temp_files_cleaned += 1
                        logger.info(f"Successfully deleted temporary Discord audio file: {temp_audio_path}")
                    else:
                        logger.debug(f"Temporary Discord audio file already deleted: {temp_audio_path}")
                except Exception as e:
                    logger.error(f"Failed to delete temporary Discord audio file {temp_audio_path}: {e}")
            
            if temp_text_file:
                temp_text_path = os.path.join("outputs", temp_text_file)
                try:
                    if os.path.exists(temp_text_path):
                        os.remove(temp_text_path)
                        temp_files_cleaned += 1
                        logger.info(f"Successfully deleted temporary Discord text file: {temp_text_path}")
                    else:
                        logger.debug(f"Temporary Discord text file already deleted: {temp_text_path}")
                except Exception as e:
                    logger.error(f"Failed to delete temporary Discord text file {temp_text_path}: {e}")
            
            # Log completion of Discord temp file cleanup
            if temp_files_cleaned > 0:
                logger.info(f"Discord notification cleanup completed - deleted {temp_files_cleaned} temporary files")

class VoiceSelector:
    """Handles voice selection logic"""
    
    # Available voices for TTS - 6 main voices as requested
    AVAILABLE_VOICES = [
        "tara",
        "leah", 
        "leo",
        "dan",
        "mia",
        "zac"
    ]
    
    # Gender-based voice categorization
    FEMALE_VOICES = ["tara", "leah", "mia"]
    MALE_VOICES = ["leo", "dan", "zac"]
    
    @staticmethod
    def get_voice(config: WorkerConfig, target_gender: Optional[str] = None) -> str:
        """
        Get voice based on configuration and target_gender
        
        Args:
            config: WorkerConfig instance
            target_gender: Target gender preference ('male', 'female', or None)
            
        Returns:
            str: Selected voice name
        """
        if config.use_random_voice:
            # Consider target_gender when selecting random voice
            if target_gender:
                gender_lower = target_gender.lower().strip()
                if gender_lower in ['female', 'woman', 'girl', 'f']:
                    selected_voice = random.choice(VoiceSelector.FEMALE_VOICES)
                    logger.info(f"Random female voice selected based on target_gender '{target_gender}': {selected_voice}")
                    return selected_voice
                elif gender_lower in ['male', 'man', 'boy', 'm']:
                    selected_voice = random.choice(VoiceSelector.MALE_VOICES)
                    logger.info(f"Random male voice selected based on target_gender '{target_gender}': {selected_voice}")
                    return selected_voice
                else:
                    logger.info(f"Unrecognized target_gender '{target_gender}', randomly choosing gender")
            
            # When no target_gender or unrecognized, randomly choose a gender first, then a voice from that gender
            if random.choice([True, False]):  # Randomly choose between male and female
                selected_voice = random.choice(VoiceSelector.FEMALE_VOICES)
                logger.info(f"Random gender selection chose female voice: {selected_voice}")
            else:
                selected_voice = random.choice(VoiceSelector.MALE_VOICES)
                logger.info(f"Random gender selection chose male voice: {selected_voice}")
            return selected_voice
        else:
            # Consider target_gender when using default voice configuration
            if target_gender:
                gender_lower = target_gender.lower().strip()
                if gender_lower in ['female', 'woman', 'girl', 'f']:
                    # Use a random female voice if configured voice doesn't match gender preference
                    if config.voice not in VoiceSelector.FEMALE_VOICES:
                        selected_voice = random.choice(VoiceSelector.FEMALE_VOICES)  # Random female voice
                        logger.info(f"Target gender is female, overriding default voice with: {selected_voice}")
                        return selected_voice
                elif gender_lower in ['male', 'man', 'boy', 'm']:
                    # Use a random male voice if configured voice doesn't match gender preference
                    if config.voice not in VoiceSelector.MALE_VOICES:
                        selected_voice = random.choice(VoiceSelector.MALE_VOICES)  # Random male voice
                        logger.info(f"Target gender is male, overriding default voice with: {selected_voice}")
                        return selected_voice
                else:
                    logger.info(f"Unrecognized target_gender '{target_gender}', using configured default voice")
            
            # Use configured default voice
            logger.info(f"Using default voice: {config.voice}")
            return config.voice

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
        
        print(f"GET NARRATION REQUEST PATH: {url}")
        
        async with self.session.get(url, headers=headers) as response:
            response_text = await response.text()
            success = response.status == 200
            
            print(f"GET NARRATION RESPONSE:")
            print(f"  Success: {success}")
            print(f"  Status Code: {response.status}")
            print(f"  Response Content: {response_text}")
            
            if response.status == 404:
                raise WorkerError("No narration available for audio generation")
            elif response.status != 200:
                try:
                    logger.error(f"Get Narration API Error - Status: {response.status}, Response: {response_text}")
                    raise WorkerError(f"Get narration failed with status {response.status}: {response_text}")
                except Exception as e:
                    logger.error(f"Get narration failed with status {response.status}, could not read response: {e}")
                    raise WorkerError(f"Get narration failed with status {response.status}")
            
            data = json.loads(response_text)
            logger.info(f"Narration retrieved for narration ID: {data.get('id')}")
            return data
    
    async def generate_tts(self, text: str, target_gender: Optional[str] = None) -> str:
        """Generate TTS audio and return file path"""
        # Select voice based on configuration and target_gender
        selected_voice = VoiceSelector.get_voice(self.config, target_gender)
        
        url = f"{self.config.tts_server_url}/v1/audio/speech"
        payload = {
            "input": text,
            "model": "orpheus",
            "voice": selected_voice,
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
        self.discord_notifier = DiscordNotifier(config)
    
    async def process_narration(self) -> bool:
        """Process a single narration through the complete pipeline"""
        logger.info(f"Worker {self.worker_id} starting narration processing")
        
        wav_file_path = None
        mp3_file_path = None
        
        try:
            async with APIClient(self.config) as api_client:
                # Step 1: Get narration
                logger.info(f"Worker {self.worker_id}: Getting narration")
                narration_data = await api_client.get_narration()
                
                narration_id = narration_data.get('id')
                if not narration_id:
                    raise WorkerError("No narration ID in narration data")
                
                # Extract text for TTS
                text_content = narration_data.get('text', '').strip()
                
                # Fallback to research data if text field is empty
                if not text_content:
                    company_research = narration_data.get('company_deep_research', '')
                    profile_research = narration_data.get('profile_deep_research', '')
                    text_content = f"{company_research}\n\n{profile_research}".strip()
                
                if not text_content:
                    raise WorkerError("No text content available for TTS")
                
                # Extract target_gender from narration data (if available)
                target_gender = narration_data.get('target_gender', None)
                
                # Step 2: Generate TTS audio (WAV format) - Track generation time
                logger.info(f"Worker {self.worker_id}: Generating TTS audio")
                generation_start_time = time.time()
                wav_file_path = await api_client.generate_tts(text_content, target_gender)
                generation_end_time = time.time()
                generation_time = round(generation_end_time - generation_start_time, 2)
                logger.info(f"Worker {self.worker_id}: TTS generation completed in {generation_time} seconds")
                
                # Step 3: Convert WAV to MP3
                logger.info(f"Worker {self.worker_id}: Converting WAV to MP3")
                try:
                    mp3_file_path = self.audio_processor.convert_wav_to_mp3(wav_file_path)
                    logger.info(f"Worker {self.worker_id}: Successfully converted to MP3: {mp3_file_path}")
                except WorkerError as e:
                    logger.error(f"Worker {self.worker_id}: MP3 conversion failed: {e}")
                    # If MP3 conversion fails, continue with WAV file
                    logger.warning(f"Worker {self.worker_id}: Continuing with WAV file due to MP3 conversion failure")
                    mp3_file_path = wav_file_path
                
                # Step 4: Get audio duration (use MP3 if available, otherwise WAV)
                logger.info(f"Worker {self.worker_id}: Calculating audio duration")
                if mp3_file_path != wav_file_path and mp3_file_path.endswith('.mp3'):
                    # Use MP3 duration calculation
                    audio_duration = self.audio_processor.get_mp3_duration(mp3_file_path)
                    if audio_duration == 0.0:
                        # Fallback to WAV duration if MP3 duration fails
                        logger.warning(f"Worker {self.worker_id}: MP3 duration calculation failed, using WAV")
                        audio_duration = self.audio_processor.get_audio_duration(wav_file_path)
                else:
                    # Use WAV duration calculation
                    audio_duration = self.audio_processor.get_audio_duration(wav_file_path)
                
                # Step 5: Upload to S3 (prefer MP3, fallback to WAV)
                logger.info(f"Worker {self.worker_id}: Uploading to S3")
                upload_file_path = mp3_file_path if mp3_file_path != wav_file_path else wav_file_path
                audio_url = await self.s3_uploader.upload_audio(upload_file_path, narration_id)
                
                # Step 6: Update narration with audio info
                logger.info(f"Worker {self.worker_id}: Updating narration")
                await api_client.update_narration_audio(narration_id, audio_url, audio_duration)
                
                # Step 7: Send Discord notification
                logger.info(f"Worker {self.worker_id}: Sending Discord notification")
                await self.discord_notifier.send_narration_summary(
                    api_client.session, narration_data, audio_url, audio_duration, self.worker_id, generation_time
                )
                
                logger.info(f"Worker {self.worker_id}: Successfully processed narration {narration_id}")
                return True
                
        except WorkerError as e:
            # Re-raise WorkerError so the manager can handle it properly
            logger.error(f"Worker {self.worker_id}: WorkerError: {e}")
            raise
        except Exception as e:
            logger.error(f"Worker {self.worker_id}: Unexpected error: {e}")
            return False
        finally:
            # Cleanup local files - ensure all generated TTS and converted files are deleted
            files_to_cleanup = []
            if wav_file_path:
                files_to_cleanup.append(wav_file_path)
            if mp3_file_path and mp3_file_path != wav_file_path:
                files_to_cleanup.append(mp3_file_path)
            
            for file_path in files_to_cleanup:
                try:
                    if os.path.exists(file_path):
                        os.remove(file_path)
                        logger.info(f"Worker {self.worker_id}: Successfully deleted generated file: {file_path}")
                    else:
                        logger.debug(f"Worker {self.worker_id}: File already deleted or doesn't exist: {file_path}")
                except Exception as e:
                    logger.error(f"Worker {self.worker_id}: Failed to delete file {file_path}: {e}")
            
            # Log completion of cleanup process
            if files_to_cleanup:
                logger.info(f"Worker {self.worker_id}: Cleanup completed for {len(files_to_cleanup)} generated files")

class WorkerManager:
    """Manages multiple workers and handles the worker lifecycle"""
    
    def __init__(self, config: WorkerConfig):
        self.config = config
        self.active_workers = {}  # worker_id -> {'task': task, 'start_time': time, 'status': status}
        self.worker_counter = 0
        self.running = False
        self.no_narrations_backoff = 0  # Backoff time when no narrations are available
        self.max_backoff = 60  # Maximum backoff time in seconds
        self.last_no_narration_time = 0
    
    async def start_worker(self) -> tuple[int, bool]:
        """Start a single worker and return (worker_id, success)"""
        self.worker_counter += 1
        worker_id = self.worker_counter
        
        if worker_id in self.active_workers:
            return worker_id, False
        
        start_time = time.time()
        self.active_workers[worker_id] = {
            'start_time': start_time,
            'status': 'starting'
        }
        
        success = False
        no_narrations_available = False
        
        try:
            worker = Worker(worker_id, self.config)
            self.active_workers[worker_id]['status'] = 'processing'
            
            # Single attempt - no retry for "no narrations available"
            try:
                success = await worker.process_narration()
                if success:
                    self.active_workers[worker_id]['status'] = 'completed'
                else:
                    self.active_workers[worker_id]['status'] = 'failed'
            except WorkerError as e:
                error_msg = str(e)
                logger.debug(f"Worker {worker_id}: WorkerError caught: {error_msg}")
                if "No narration available for audio generation" in error_msg:
                    no_narrations_available = True
                    self.active_workers[worker_id]['status'] = 'no_narrations'
                    logger.info(f"Worker {worker_id}: No narrations available - setting backoff flag")
                else:
                    logger.error(f"Worker {worker_id}: Error: {e}")
                    self.active_workers[worker_id]['status'] = 'error'
            except Exception as e:
                error_msg = str(e)
                logger.debug(f"Worker {worker_id}: General exception caught: {error_msg}")
                if "No narration available for audio generation" in error_msg:
                    no_narrations_available = True
                    self.active_workers[worker_id]['status'] = 'no_narrations'
                    logger.info(f"Worker {worker_id}: No narrations available (general exception) - setting backoff flag")
                else:
                    logger.error(f"Worker {worker_id}: Unexpected error: {e}")
                    self.active_workers[worker_id]['status'] = 'error'
            
        except Exception as e:
            logger.error(f"Worker {worker_id}: Fatal error: {e}")
            self.active_workers[worker_id]['status'] = 'error'
        finally:
            self.active_workers.pop(worker_id, None)
            logger.info(f"Worker {worker_id}: Finished")
        
        # Update backoff logic based on result
        if no_narrations_available:
            current_time = time.time()
            self.last_no_narration_time = current_time
            # Increase backoff time (exponential backoff with max limit)
            if self.no_narrations_backoff == 0:
                self.no_narrations_backoff = 5  # Start with 5 seconds
            else:
                self.no_narrations_backoff = min(self.no_narrations_backoff * 2, self.max_backoff)
            logger.info(f"No narrations available, backing off for {self.no_narrations_backoff} seconds")
        elif success:
            # Reset backoff on successful processing
            self.no_narrations_backoff = 0
            logger.info("Successfully processed narration, resetting backoff")
        
        return worker_id, success
    
    def should_start_new_worker(self) -> bool:
        """Determine if we should start a new worker based on current state"""
        current_time = time.time()
        
        # If we're in backoff mode due to no narrations, don't start new workers
        if self.no_narrations_backoff > 0:
            time_since_last_no_narration = current_time - self.last_no_narration_time
            if time_since_last_no_narration < self.no_narrations_backoff:
                return False
            else:
                # Backoff period has passed, reset and allow one worker to check
                logger.info("Backoff period ended, allowing one worker to check for narrations")
                self.no_narrations_backoff = 0
                return len(self.active_workers) == 0  # Only start if no workers are active
        
        # Normal operation: start workers up to max limit
        active_count = len(self.active_workers)
        
        if active_count == 0:
            # No workers running, start one
            return True
        elif active_count < self.config.max_workers:
            # Check if any worker has been processing for more than 30 seconds
            # This indicates they're actually working on a narration
            for worker_info in self.active_workers.values():
                if worker_info['status'] == 'processing':
                    processing_time = current_time - worker_info['start_time']
                    if processing_time > 30:  # Worker has been busy for 30+ seconds
                        return True
        
        return False
    
    async def run(self) -> None:
        """Run the worker system continuously with smart worker management"""
        logger.info(f"Starting worker system with {self.config.max_workers} max workers")
        logger.info("Smart worker management enabled: will start with one worker and scale based on demand")
        self.running = True
        
        try:
            while self.running:
                if self.should_start_new_worker():
                    logger.info(f"Starting new worker (active: {len(self.active_workers)})")
                    asyncio.create_task(self.start_worker())
                
                # Wait before checking again
                await asyncio.sleep(2)
                
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
