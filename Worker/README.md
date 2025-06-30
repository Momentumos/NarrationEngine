# Orpheus Worker System

A multi-threaded worker system for processing narrations through the complete pipeline: authentication, narration retrieval, TTS generation, S3 upload, and API updates.

## Features

- **Multi-worker processing**: Configurable number of concurrent workers
- **Complete pipeline**: Handles the full workflow from authentication to final API updates
- **Robust error handling**: Retry logic with configurable attempts and delays
- **AWS S3 integration**: Automatic audio file upload and URL generation
- **Async operations**: High-performance async/await implementation
- **Configurable**: Environment-based configuration with CLI overrides

## Quick Start

1. **Setup the environment**:
   ```bash
   python setup.py
   ```

2. **Configure your environment**:
   Edit the `.env` file with your actual values:
   ```bash
   # Required
   API_BASE_URL=https://your-api-url.com
   SERVER_TO_SERVER_API_KEY='your_server_api_key_here'
   AWS_ACCESS_KEY_ID=your_actual_access_key
   AWS_SECRET_ACCESS_KEY=your_actual_secret_key
   S3_BUCKET=your-actual-bucket-name
   
   # Optional (defaults provided)
   TTS_SERVER_URL=http://localhost:5005
   MAX_WORKERS=3
   WORKER_TIMEOUT=300
   RETRY_ATTEMPTS=3
   RETRY_DELAY=5
   ```

3. **Run the workers**:
   ```bash
   python run_workers.py
   ```

## Installation

### Manual Installation

1. **Install dependencies**:
   ```bash
   pip install -r requirements.txt
   ```

2. **Create environment file**:
   ```bash
   cp .env.example .env
   ```

3. **Edit configuration**:
   ```bash
   nano .env  # or your preferred editor
   ```

4. **Create outputs directory**:
   ```bash
   mkdir -p outputs
   ```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `API_BASE_URL` | ✅ | - | Base URL for the API server |
| `TTS_SERVER_URL` | ❌ | `http://localhost:5005` | TTS server endpoint |
| `AWS_ACCESS_KEY_ID` | ✅ | - | AWS access key for S3 |
| `AWS_SECRET_ACCESS_KEY` | ✅ | - | AWS secret key for S3 |
| `AWS_REGION` | ❌ | `us-east-1` | AWS region for S3 |
| `S3_BUCKET` | ✅ | - | S3 bucket name for audio files |
| `MAX_WORKERS` | ❌ | `3` | Maximum concurrent workers |
| `WORKER_TIMEOUT` | ❌ | `300` | Worker timeout in seconds |
| `RETRY_ATTEMPTS` | ❌ | `3` | Number of retry attempts |
| `RETRY_DELAY` | ❌ | `5` | Delay between retries in seconds |

### CLI Options

```bash
python run_workers.py --help
```

Options:
- `--workers, -w`: Number of concurrent workers
- `--api-url`: Override API base URL
- `--tts-url`: Override TTS server URL
- `--verbose, -v`: Enable verbose logging

## Usage Examples

### Basic Usage
```bash
python run_workers.py
```

### Custom Worker Count
```bash
python run_workers.py --workers 5
```

### Override URLs
```bash
python run_workers.py --api-url https://custom-api.com --tts-url http://localhost:8080
```

### Verbose Logging
```bash
python run_workers.py --verbose
```

## Architecture

### Worker Pipeline

Each worker processes narrations through these steps:

1. **Authentication**: Phone login and verification
2. **Narration Retrieval**: Get pending narration data
3. **TTS Generation**: Convert text to audio
4. **Audio Processing**: Calculate duration and prepare file
5. **S3 Upload**: Upload audio file to AWS S3
6. **API Update**: Update podcast with audio URL and metadata
7. **Cleanup**: Remove temporary local files

### Components

- **WorkerManager**: Manages worker lifecycle and concurrency
- **Worker**: Individual worker that processes single narrations
- **APIClient**: Handles all API communications
- **S3Uploader**: Manages S3 upload operations
- **AudioProcessor**: Handles audio file processing

## Error Handling

- **Retry Logic**: Configurable retry attempts with delays
- **Graceful Shutdown**: Proper cleanup on interruption
- **Comprehensive Logging**: Detailed logs for debugging
- **Exception Handling**: Specific error types for different failures

## Monitoring

The system provides detailed logging including:
- Worker lifecycle events
- API request/response status
- S3 upload progress
- Error details and retry attempts
- Performance metrics

## Troubleshooting

### Common Issues

1. **Missing Environment Variables**:
   ```
   ❌ Missing required environment variables: AWS_ACCESS_KEY_ID, S3_BUCKET
   ```
   Solution: Check your `.env` file and ensure all required variables are set.

2. **S3 Upload Failures**:
   ```
   S3 upload failed: NoCredentialsError
   ```
   Solution: Verify your AWS credentials and permissions.

3. **TTS Server Connection**:
   ```
   TTS generation failed with status 500
   ```
   Solution: Ensure the TTS server is running and accessible.

4. **API Authentication**:
   ```
   Verification failed with status 401
   ```
   Solution: Check API credentials and endpoint configuration.

### Debug Mode

Enable verbose logging for detailed debugging:
```bash
python run_workers.py --verbose
```

## Development

### Project Structure
```
Worker/
├── worker_system.py    # Main worker system implementation
├── run_workers.py      # CLI runner script
├── setup.py           # Setup and installation script
├── requirements.txt   # Python dependencies
├── .env.example      # Environment template
├── .env              # Your configuration (create from .env.example)
├── outputs/          # Temporary audio files (auto-created)
└── README.md         # This file
```

### Dependencies

- `aiohttp`: Async HTTP client
- `python-dotenv`: Environment variable management
- `boto3`: AWS SDK for S3 operations
- `botocore`: AWS core library

## License

This project is part of the Orpheus-FastAPI system.
