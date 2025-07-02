# Orpheus Worker Daemon Guide

This guide explains how to run the Orpheus Worker System in daemon mode for production environments.

## 🚀 Quick Start

### Method 1: Using the Management Script (Recommended)

```bash
# Make scripts executable (if not already done)
chmod +x worker_daemon.sh daemon_worker.py

# Start the daemon
./worker_daemon.sh start

# Check status
./worker_daemon.sh status

# View logs
./worker_daemon.sh logs

# Follow logs in real-time
./worker_daemon.sh follow

# Stop the daemon
./worker_daemon.sh stop
```

### Method 2: Direct Python Daemon

```bash
# Start daemon
python3 daemon_worker.py start

# Check status
python3 daemon_worker.py status

# Stop daemon
python3 daemon_worker.py stop
```

### Method 3: Systemd Service (Linux Production)

```bash
# Copy and edit the service file
sudo cp orpheus-worker.service /etc/systemd/system/
sudo nano /etc/systemd/system/orpheus-worker.service

# Edit paths in the service file to match your setup
# Then enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable orpheus-worker
sudo systemctl start orpheus-worker
```

## 📋 Available Commands

### Management Script Commands

| Command | Description |
|---------|-------------|
| `start` | Start the daemon in background |
| `stop` | Stop the daemon |
| `restart` | Restart the daemon |
| `status` | Show daemon status and recent activity |
| `logs [N]` | Show last N lines of logs (default: 50) |
| `follow` | Follow logs in real-time (Ctrl+C to stop) |
| `run` | Run in foreground mode (for debugging) |
| `help` | Show help message |

### Examples

```bash
# Start daemon
./worker_daemon.sh start

# Check if running
./worker_daemon.sh status

# Show last 100 log lines
./worker_daemon.sh logs 100

# Follow logs in real-time
./worker_daemon.sh follow

# Run in foreground for debugging
./worker_daemon.sh run

# Restart daemon
./worker_daemon.sh restart
```

## 🔧 Configuration

### Environment Variables

Make sure your `.env` file contains all required variables:

```bash
# API Configuration
API_BASE_URL=https://your-api-server.com
SERVER_TO_SERVER_API_KEY=your_api_key_here
TTS_SERVER_URL=http://localhost:5005

# AWS S3 Configuration
AWS_ACCESS_KEY_ID=your_aws_access_key
AWS_SECRET_ACCESS_KEY=your_aws_secret_key
AWS_REGION=us-east-1
S3_BUCKET=your-s3-bucket-name

# Worker Configuration
MAX_WORKERS=3
WORKER_TIMEOUT=300
USE_RANDOM_VOICE=true

# Optional: Discord Notifications
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
```

### File Locations

- **Daemon Script**: `daemon_worker.py`
- **Management Script**: `worker_daemon.sh`
- **PID File**: `worker_daemon.pid`
- **Log File**: `worker_daemon.log`
- **Config File**: `.env`
- **Systemd Service**: `orpheus-worker.service`

## 📊 Monitoring

### Check Daemon Status

```bash
./worker_daemon.sh status
```

Output example:
```
Daemon is running (PID 12345)
Log file: /path/to/worker_daemon.log
Last activity: 2025-01-03 12:00:00

Last 5 log entries:
  2025-01-03 12:00:00 - worker_system - INFO - Worker 1: Successfully processed narration abc123
  2025-01-03 11:59:45 - worker_system - INFO - Random male voice selected: dan
  2025-01-03 11:59:30 - worker_system - INFO - Worker 1: Generating TTS audio
```

### View Logs

```bash
# Show last 50 lines (default)
./worker_daemon.sh logs

# Show last 100 lines
./worker_daemon.sh logs 100

# Follow logs in real-time
./worker_daemon.sh follow
```

### Log Rotation

For production, consider setting up log rotation:

```bash
# Create logrotate configuration
sudo nano /etc/logrotate.d/orpheus-worker
```

Add this content:
```
/path/to/your/Worker/worker_daemon.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 your_user your_group
    postrotate
        /path/to/your/Worker/worker_daemon.sh restart > /dev/null 2>&1 || true
    endscript
}
```

## 🐧 Systemd Service Setup (Linux)

### 1. Edit Service File

```bash
sudo cp orpheus-worker.service /etc/systemd/system/
sudo nano /etc/systemd/system/orpheus-worker.service
```

Update these paths in the service file:
- `/path/to/your/Worker` → Your actual Worker directory path
- `www-data` → Your preferred user (or create a dedicated user)

### 2. Create Dedicated User (Recommended)

```bash
# Create system user for the service
sudo useradd --system --no-create-home --shell /bin/false orpheus

# Set ownership of Worker directory
sudo chown -R orpheus:orpheus /path/to/your/Worker

# Update service file to use orpheus user instead of www-data
```

### 3. Enable and Start Service

```bash
# Reload systemd
sudo systemctl daemon-reload

# Enable service to start on boot
sudo systemctl enable orpheus-worker

# Start service
sudo systemctl start orpheus-worker

# Check status
sudo systemctl status orpheus-worker
```

### 4. Systemd Commands

```bash
# Start service
sudo systemctl start orpheus-worker

# Stop service
sudo systemctl stop orpheus-worker

# Restart service
sudo systemctl restart orpheus-worker

# Check status
sudo systemctl status orpheus-worker

# View logs
sudo journalctl -u orpheus-worker -f

# View recent logs
sudo journalctl -u orpheus-worker --since "1 hour ago"
```

## 🔍 Troubleshooting

### Common Issues

#### 1. Daemon Won't Start

```bash
# Check dependencies
python3 -c "import asyncio, aiohttp, boto3, dotenv"

# Check .env file
cat .env

# Check permissions
ls -la daemon_worker.py worker_daemon.sh

# Run in foreground to see errors
./worker_daemon.sh run
```

#### 2. Permission Denied

```bash
# Make scripts executable
chmod +x worker_daemon.sh daemon_worker.py

# Check file ownership
ls -la

# Fix ownership if needed
chown $USER:$USER *
```

#### 3. Python Module Not Found

```bash
# Install requirements
pip3 install -r requirements.txt

# Or use virtual environment
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

#### 4. Daemon Stops Unexpectedly

```bash
# Check logs for errors
./worker_daemon.sh logs 200

# Check system resources
free -h
df -h

# Check for OOM killer
dmesg | grep -i "killed process"
```

### Debug Mode

Run in foreground to see all output:

```bash
./worker_daemon.sh run
```

This will show all logs in real-time and help identify issues.

## 🔄 Auto-Restart on Failure

### Using Systemd (Recommended)

The systemd service automatically restarts on failure with the `Restart=always` setting.

### Using Cron (Alternative)

Add to crontab for periodic health checks:

```bash
crontab -e
```

Add this line:
```bash
*/5 * * * * /path/to/your/Worker/worker_daemon.sh status > /dev/null || /path/to/your/Worker/worker_daemon.sh start
```

## 📈 Performance Tuning

### Worker Configuration

Adjust these environment variables in `.env`:

```bash
# Number of concurrent workers
MAX_WORKERS=3

# Worker timeout (seconds)
WORKER_TIMEOUT=300

# Retry configuration
RETRY_ATTEMPTS=3
RETRY_DELAY=5
```

### System Resources

Monitor system resources:

```bash
# CPU and memory usage
htop

# Disk usage
df -h

# Network connections
netstat -tulpn | grep python
```

## 🔐 Security Considerations

### File Permissions

```bash
# Secure .env file
chmod 600 .env

# Secure log files
chmod 644 worker_daemon.log

# Secure PID file
chmod 644 worker_daemon.pid
```

### Systemd Security

The provided service file includes security settings:
- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectSystem=strict`
- `ProtectHome=true`

### Network Security

- Use HTTPS for API endpoints
- Secure AWS credentials
- Use VPC/firewall rules to restrict access

## 📞 Support

If you encounter issues:

1. Check the logs: `./worker_daemon.sh logs`
2. Run in foreground: `./worker_daemon.sh run`
3. Verify configuration: Check `.env` file
4. Check system resources: CPU, memory, disk space
5. Review the troubleshooting section above

## 🎯 Production Checklist

- [ ] `.env` file configured with production values
- [ ] Log rotation configured
- [ ] Systemd service installed and enabled
- [ ] Monitoring/alerting set up
- [ ] Backup strategy for logs and configuration
- [ ] Security hardening applied
- [ ] Resource limits configured
- [ ] Auto-restart mechanism in place
