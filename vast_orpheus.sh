#!/bin/bash
set -e

# Trap function to handle script completion and cloud-init warnings
cleanup_and_finish() {
    local exit_code=$?
    echo ""
    echo "🔧 Performing final cleanup..."
    
    # Fix cloud-init permissions issue that causes warnings on Vast.ai
    if [ -d "/var/lib/cloud/instance" ]; then
        touch /var/lib/cloud/instance/boot-finished 2>/dev/null || true
        chmod 644 /var/lib/cloud/instance/boot-finished 2>/dev/null || true
    fi
    
    # Ensure all services are properly started (handle both systemd and non-systemd systems)
    if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        # System has systemd and it's running
        systemctl is-active --quiet nginx || systemctl restart nginx 2>/dev/null || service nginx restart 2>/dev/null || true
        systemctl is-active --quiet supervisor || systemctl restart supervisor 2>/dev/null || service supervisor restart 2>/dev/null || true
    else
        # System doesn't have systemd or it's not running, use service command
        service nginx status >/dev/null 2>&1 || service nginx restart 2>/dev/null || true
        service supervisor status >/dev/null 2>&1 || service supervisor restart 2>/dev/null || true
    fi
    
    if [ $exit_code -eq 0 ]; then
        echo "✅ Script completed successfully!"
        echo "🔍 Final system check..."
        
        # Quick health check
        if curl -s --connect-timeout 5 http://localhost:8000 > /dev/null 2>&1; then
            echo "✅ Web interface is accessible on port 8000"
        else
            echo "⚠️ Web interface may still be starting up"
        fi
        
        if docker ps | grep -q orpheus-fastapi; then
            echo "✅ Docker containers are running"
        else
            echo "⚠️ Docker container status unknown"
        fi
        
        echo ""
        echo "🎯 Setup completed! Any cloud-init warnings above can be safely ignored."
        echo "🌐 Access your TTS server at: http://localhost:8000"
    else
        echo "❌ Script encountered an error (exit code: $exit_code)"
    fi
    
    exit $exit_code
}

# Set trap to run cleanup function on script exit
trap cleanup_and_finish EXIT

echo "🚀 Starting Orpheus-FastAPI Docker Setup for Vast.ai (Ubuntu 22.04 Base Image)..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root (use sudo)"
    echo "💡 Run: sudo bash $0"
    exit 1
fi

# Check if we're on a supported system
if ! command -v apt-get >/dev/null 2>&1; then
    echo "❌ This script requires a Debian/Ubuntu-based system"
    exit 1
fi

# STEP 1: Update system packages
echo "📦 Step 1: Updating system packages..."
export DEBIAN_FRONTEND=noninteractive

# Configure Ubuntu mirrors for faster package downloads in China
echo "🔧 Configuring Ubuntu mirrors for faster downloads in China..."
sed -i 's|http://.*.ubuntu.com|http://mirrors.ustc.edu.cn|g' /etc/apt/sources.list
sed -i 's|https://.*.ubuntu.com|http://mirrors.ustc.edu.cn|g' /etc/apt/sources.list
# Also configure additional mirrors as backup
sed -i 's|security.ubuntu.com|mirrors.ustc.edu.cn|g' /etc/apt/sources.list

# Configure DNS to avoid network interference
echo "🔧 Configuring DNS for better connectivity..."
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 114.114.114.114" >> /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# Disable IPv6 to avoid connectivity issues
echo "🔧 Disabling IPv6 to improve connectivity..."
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p 2>/dev/null || true

# Handle potential cloud-init conflicts during package installation
echo "🔧 Preparing system for package installation..."
# Wait for any ongoing cloud-init processes to complete
if command -v cloud-init >/dev/null 2>&1; then
    echo "⏳ Waiting for cloud-init to complete..."
    cloud-init status --wait 2>/dev/null || true
fi

# Ensure package manager is not locked (simplified approach)
echo "🔍 Checking package manager availability..."

# Simple check - just wait a moment and try to acquire the lock briefly
# This avoids the problematic fuser command that can hang
if command -v apt-get >/dev/null 2>&1; then
    # Try a quick, non-destructive apt command to test availability
    echo "🔄 Testing package manager availability..."
    if timeout 10 apt-get check >/dev/null 2>&1; then
        echo "✅ Package manager is available"
    else
        echo "⚠️ Package manager test failed, but proceeding anyway..."
        echo "🔍 This might be normal in some containerized environments"
    fi
else
    echo "⚠️ apt-get not found, skipping lock check"
fi

echo "🔄 Running sudo apt-get update..."
apt-get update -qq

# STEP 2: Upgrade system packages
echo "📦 Step 2: Upgrading system packages..."
echo "🔄 Running sudo apt-get upgrade..."
apt-get upgrade -y -qq

# STEP 3: Install Docker and Docker Compose
echo "🐳 Step 3: Installing Docker and Docker Compose..."

# Check if Docker is already installed (likely in Vast.ai KVM image)
if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 Installing Docker..."
    apt-get install -y -qq \
        ca-certificates \
        gnupg \
        lsb-release
    
    # Check if Docker GPG key already exists
    if [ ! -f /usr/share/keyrings/docker-archive-keyring.gpg ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    fi
    
    # Check if Docker repository already exists
    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
    fi
    
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    echo "✅ Docker already installed"
fi

# Install additional required packages
apt-get install -y -qq \
    curl \
    git \
    nginx \
    supervisor

# Ensure Docker Compose is installed and available
echo "🔧 Ensuring Docker Compose is installed..."
DOCKER_COMPOSE_CMD=""

# Method 1: Check for standalone docker-compose command
if command -v docker-compose >/dev/null 2>&1; then
    echo "✅ docker-compose command found"
    DOCKER_COMPOSE_CMD="docker-compose"
    # Verify it works
    if docker-compose --version >/dev/null 2>&1; then
        echo "✅ docker-compose is functional"
    else
        echo "⚠️ docker-compose found but not functional, will reinstall"
        DOCKER_COMPOSE_CMD=""
    fi
fi

# Method 2: Check for docker compose plugin
if [ -z "$DOCKER_COMPOSE_CMD" ] && docker compose version >/dev/null 2>&1; then
    echo "✅ docker compose plugin found"
    DOCKER_COMPOSE_CMD="docker compose"
fi

# Method 3: Install Docker Compose if not found or not working
if [ -z "$DOCKER_COMPOSE_CMD" ]; then
    echo "🔧 Installing Docker Compose..."
    
    # Try installing via apt first (more reliable on Ubuntu)
    echo "📦 Attempting installation via apt..."
    if apt-get install -y -qq docker-compose-plugin docker-compose; then
        # Check which one works
        if command -v docker-compose >/dev/null 2>&1 && docker-compose --version >/dev/null 2>&1; then
            echo "✅ Docker Compose installed via apt (standalone)"
            DOCKER_COMPOSE_CMD="docker-compose"
        elif docker compose version >/dev/null 2>&1; then
            echo "✅ Docker Compose installed via apt (plugin)"
            DOCKER_COMPOSE_CMD="docker compose"
        fi
    fi
    
    # If apt installation failed, try manual installation
    if [ -z "$DOCKER_COMPOSE_CMD" ]; then
        echo "📥 Attempting manual installation..."
        # Get latest version
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
        if [ -z "$COMPOSE_VERSION" ]; then
            COMPOSE_VERSION="v2.24.0"  # Fallback version
        fi
        
        curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        
        # Verify manual installation
        if command -v docker-compose >/dev/null 2>&1 && docker-compose --version >/dev/null 2>&1; then
            echo "✅ Docker Compose installed manually"
            DOCKER_COMPOSE_CMD="docker-compose"
        else
            echo "❌ Manual installation failed, using docker compose plugin as fallback"
            DOCKER_COMPOSE_CMD="docker compose"
        fi
    fi
fi

# Final verification
echo "🔍 Final Docker Compose verification..."
if [ "$DOCKER_COMPOSE_CMD" = "docker-compose" ]; then
    if docker-compose --version; then
        echo "✅ Docker Compose (standalone) is ready: $(docker-compose --version)"
    else
        echo "❌ Docker Compose standalone failed, switching to plugin"
        DOCKER_COMPOSE_CMD="docker compose"
    fi
fi

if [ "$DOCKER_COMPOSE_CMD" = "docker compose" ]; then
    if docker compose version; then
        echo "✅ Docker Compose (plugin) is ready: $(docker compose version)"
    else
        echo "❌ Docker Compose plugin also failed - this is a critical error"
        exit 1
    fi
fi

# Create a wrapper script for consistent docker-compose usage
echo "🔧 Creating docker-compose wrapper..."
cat > /usr/local/bin/docker-compose-wrapper << EOF
#!/bin/bash
if command -v docker-compose >/dev/null 2>&1; then
    exec docker-compose "\$@"
else
    exec docker compose "\$@"
fi
EOF
chmod +x /usr/local/bin/docker-compose-wrapper

# Install NVIDIA Docker runtime if not present
if ! command -v nvidia-container-runtime >/dev/null 2>&1; then
    echo "🎮 Installing NVIDIA Docker runtime..."
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    
    # Check if NVIDIA GPG key already exists
    if [ ! -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ]; then
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    fi
    
    # Check if NVIDIA repository already exists
    if [ ! -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]; then
        curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt-get update -qq
    fi
    
    apt-get install -y -qq nvidia-docker2
else
    echo "✅ NVIDIA Docker runtime already installed"
fi

# Configure Docker for NVIDIA runtime (Vast.ai compatible)
echo "🔄 Configuring Docker for Vast.ai..."

# First, try to start Docker daemon manually if it's not running
echo "🚀 Ensuring Docker daemon is running..."
if ! docker info > /dev/null 2>&1; then
    echo "📋 Docker not responding, attempting to start..."
    
    # Try multiple methods to start Docker
    echo "🔧 Method 1: Using service command..."
    if command -v service >/dev/null 2>&1; then
        service docker start 2>/dev/null || echo "Service command failed"
        # Give it more time to actually start
        sleep 5
        
        # Check if it's actually working now
        if docker info > /dev/null 2>&1; then
            echo "✅ Docker started successfully via service command"
        else
            echo "⚠️ Service command reported success but Docker still not responding"
        fi
    fi
    
    # Try systemctl only if systemd is actually running and Docker isn't working yet
    if ! docker info > /dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        echo "🔧 Method 1b: Using systemctl..."
        systemctl start docker 2>/dev/null || echo "Systemctl command failed"
        sleep 5
        
        if docker info > /dev/null 2>&1; then
            echo "✅ Docker started successfully via systemctl"
        else
            echo "⚠️ Systemctl command failed or Docker still not responding"
        fi
    fi
    
    # If Docker still not working, try direct startup
    if ! docker info > /dev/null 2>&1; then
        echo "🔧 Method 2: Starting dockerd directly..."
        
        # Kill any existing processes more thoroughly
        echo "🧹 Cleaning up existing Docker processes..."
        pkill -f dockerd 2>/dev/null || true
        pkill -f containerd 2>/dev/null || true
        pkill -f docker-proxy 2>/dev/null || true
        sleep 3
        
        # Remove any stale socket files
        rm -f /var/run/docker.sock 2>/dev/null || true
        rm -f /var/run/containerd/containerd.sock 2>/dev/null || true
        
        # Create log directory if it doesn't exist
        mkdir -p /tmp/docker-logs
        
        # Start containerd first
        echo "🔧 Starting containerd..."
        if command -v containerd >/dev/null 2>&1; then
            nohup containerd > /tmp/docker-logs/containerd.log 2>&1 &
            CONTAINERD_PID=$!
            sleep 5
            
            # Check if containerd is running
            if kill -0 $CONTAINERD_PID 2>/dev/null; then
                echo "✅ containerd started (PID: $CONTAINERD_PID)"
            else
                echo "❌ containerd failed to start"
            fi
        else
            echo "⚠️ containerd command not found"
        fi
        
        # Start dockerd with container-friendly options
        echo "🔧 Starting dockerd with container-friendly configuration..."
        if command -v dockerd >/dev/null 2>&1; then
            # Try with restricted permissions and alternative storage driver
            nohup dockerd \
                --host=unix:///var/run/docker.sock \
                --log-level=info \
                --storage-driver=vfs \
                --iptables=false \
                --bridge=none \
                --ip-forward=false \
                --ip-masq=false \
                --userland-proxy=false \
                > /tmp/docker-logs/dockerd.log 2>&1 &
            DOCKERD_PID=$!
            sleep 8
            
            # Check if dockerd is running
            if kill -0 $DOCKERD_PID 2>/dev/null; then
                echo "✅ dockerd started with restricted config (PID: $DOCKERD_PID)"
            else
                echo "❌ dockerd failed to start with restricted config"
                echo "📋 Recent dockerd logs:"
                tail -20 /tmp/docker-logs/dockerd.log 2>/dev/null || echo "No logs available"
                
                # Try with even more restricted options
                echo "🔧 Trying with minimal dockerd configuration..."
                pkill -f dockerd 2>/dev/null || true
                sleep 2
                
                nohup dockerd \
                    --host=unix:///var/run/docker.sock \
                    --log-level=info \
                    --storage-driver=vfs \
                    --iptables=false \
                    --bridge=none \
                    --ip-forward=false \
                    --ip-masq=false \
                    --userland-proxy=false \
                    --exec-opt native.cgroupdriver=cgroupfs \
                    --cgroup-parent="" \
                    > /tmp/docker-logs/dockerd-minimal.log 2>&1 &
                DOCKERD_PID=$!
                sleep 8
                
                if kill -0 $DOCKERD_PID 2>/dev/null; then
                    echo "✅ dockerd started with minimal config (PID: $DOCKERD_PID)"
                else
                    echo "❌ dockerd failed to start even with minimal config"
                    echo "📋 Recent minimal dockerd logs:"
                    tail -20 /tmp/docker-logs/dockerd-minimal.log 2>/dev/null || echo "No logs available"
                fi
            fi
        else
            echo "❌ dockerd command not found"
        fi
    fi
fi

# Wait for Docker to be available with extended timeout
echo "⏳ Waiting for Docker to be available..."
for i in {1..60}; do
    if docker info > /dev/null 2>&1; then
        echo "✅ Docker is available"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "❌ Docker is not available after extended waiting"
        echo "🔍 Debugging information:"
        echo "Docker processes:"
        ps aux | grep -E "(docker|containerd)" | grep -v grep || echo "No Docker processes found"
        echo ""
        echo "Docker socket:"
        ls -la /var/run/docker.sock 2>/dev/null || echo "Docker socket not found"
        echo ""
        echo "Recent Docker logs:"
        tail -20 /tmp/docker-logs/dockerd.log 2>/dev/null || echo "No Docker logs found"
        echo ""
        echo "Recent containerd logs:"
        tail -10 /tmp/docker-logs/containerd.log 2>/dev/null || echo "No containerd logs found"
        echo ""
        echo "❌ Unable to start Docker. This might be a Vast.ai configuration issue."
        echo "💡 Try using a different Vast.ai template or contact Vast.ai support."
        exit 1
    fi
    if [ $((i % 10)) -eq 0 ]; then
        echo "⏳ Still waiting for Docker... ($i/60)"
        # Show some debugging info every 10 seconds
        echo "   Current Docker processes: $(ps aux | grep -E "(docker|containerd)" | grep -v grep | wc -l)"
        if [ -f /tmp/docker-logs/dockerd.log ]; then
            echo "   Latest dockerd log: $(tail -1 /tmp/docker-logs/dockerd.log 2>/dev/null || echo 'No recent logs')"
        fi
        if [ -S /var/run/docker.sock ]; then
            echo "   Docker socket exists: ✅"
        else
            echo "   Docker socket exists: ❌"
        fi
    fi
    sleep 1
done

# Configure NVIDIA Docker runtime if not already configured
echo "🎮 Configuring NVIDIA Docker runtime..."
if [ -f /usr/bin/nvidia-container-runtime ]; then
    # Create or update Docker daemon configuration with container-friendly settings
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "/usr/bin/nvidia-container-runtime",
            "runtimeArgs": []
        }
    },
    "registry-mirrors": [
        "http://hub-mirror.c.163.com",
        "http://docker.mirrors.ustc.edu.cn",
        "http://mirror.baidubce.com"
    ],
    "insecure-registries": [
        "hub-mirror.c.163.com",
        "docker.mirrors.ustc.edu.cn",
        "mirror.baidubce.com"
    ],
    "storage-driver": "vfs",
    "iptables": false,
    "bridge": "none",
    "ip-forward": false,
    "ip-masq": false,
    "userland-proxy": false,
    "max-concurrent-downloads": 3,
    "max-download-attempts": 5,
    "dns": ["8.8.8.8", "114.114.114.114"]
}
EOF
    
    # Reload Docker configuration if possible
    if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        # System has systemd and it's running
        systemctl reload docker 2>/dev/null || systemctl restart docker 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        # Use service command for non-systemd systems
        service docker restart 2>/dev/null || true
    else
        # Send HUP signal to dockerd to reload config
        pkill -HUP dockerd 2>/dev/null || true
    fi
    
    # Wait for Docker to be ready after config change
    sleep 5
    for i in {1..10}; do
        if docker info > /dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    
    echo "✅ NVIDIA Docker runtime configured"
else
    echo "⚠️  NVIDIA container runtime not found, using default Docker runtime"
    # Create Docker daemon configuration with registry mirrors for better connectivity
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
    "registry-mirrors": [
        "http://hub-mirror.c.163.com",
        "http://docker.mirrors.ustc.edu.cn",
        "http://mirror.baidubce.com"
    ],
    "insecure-registries": [
        "hub-mirror.c.163.com",
        "docker.mirrors.ustc.edu.cn",
        "mirror.baidubce.com"
    ],
    "storage-driver": "vfs",
    "iptables": false,
    "bridge": "none",
    "ip-forward": false,
    "ip-masq": false,
    "userland-proxy": false,
    "max-concurrent-downloads": 3,
    "max-download-attempts": 5,
    "dns": ["8.8.8.8", "114.114.114.114"]
}
EOF
    
    # Reload Docker configuration if possible
    if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        # System has systemd and it's running
        systemctl reload docker 2>/dev/null || systemctl restart docker 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        # Use service command for non-systemd systems
        service docker restart 2>/dev/null || true
    else
        # Send HUP signal to dockerd to reload config
        pkill -HUP dockerd 2>/dev/null || true
    fi
    
    # Wait for Docker to be ready after config change
    sleep 5
    for i in {1..10}; do
        if docker info > /dev/null 2>&1; then
            break
        fi
        sleep 2
    done
fi

# Verify Docker is working
if docker info > /dev/null 2>&1; then
    echo "✅ Docker is ready for use"
    # Show Docker info for debugging
    echo "📊 Docker system info:"
    docker version --format 'Docker version: {{.Server.Version}}' 2>/dev/null || echo "Docker version: Unknown"
    if docker info 2>/dev/null | grep -q nvidia; then
        echo "🎮 NVIDIA runtime: Enabled"
    else
        echo "🎮 NVIDIA runtime: Not detected (will use default runtime)"
    fi
else
    echo "❌ Docker is not working properly"
    exit 1
fi

# Create application directory
echo "📁 Setting up application directory..."
mkdir -p /workspace/narration-engine
cd /workspace/narration-engine

# Clone the repository
echo "📥 Cloning repository..."
if [ -d ".git" ]; then
    echo "🔄 Repository already exists, pulling latest changes..."
    git pull origin main || git pull origin master || echo "⚠️ Could not pull latest changes, using existing files"
else
    echo "📥 Cloning fresh repository..."
    # Remove any existing files first
    rm -rf * .[^.]* 2>/dev/null || true
    git clone https://github.com/momentumos/NarrationEngine .
fi

# STEP 4: Copy .env.example to .env
echo "⚙️ Step 4: Setting up environment configuration..."
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        echo "✅ Copied .env.example to .env"
    else
        echo "⚠️ .env.example not found, creating basic .env file"
        cat > .env << 'EOF'
# Orpheus FastAPI Configuration
ORPHEUS_API_URL=http://llama-cpp-server:5006/v1/completions
ORPHEUS_API_TIMEOUT=120
ORPHEUS_MAX_TOKENS=4096
ORPHEUS_TEMPERATURE=0.6
ORPHEUS_TOP_P=0.9
ORPHEUS_SAMPLE_RATE=24000
ORPHEUS_MODEL_NAME=Llama-3.2-3B-Instruct-Q4_K_M.gguf
ORPHEUS_PORT=5005
ORPHEUS_HOST=0.0.0.0
EOF
    fi
else
    echo "✅ .env file already exists"
fi

# Update .env file with Vast.ai template environment variables
echo "🔧 Updating .env with Vast.ai template variables..."

# Function to update or add environment variable in .env file
update_env_var() {
    local var_name="$1"
    local var_value="$2"
    local env_file=".env"
    
    if [ -n "$var_value" ]; then
        if grep -q "^${var_name}=" "$env_file"; then
            # Update existing variable
            sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
            echo "   ✓ Updated ${var_name}"
        else
            # Add new variable
            echo "${var_name}=${var_value}" >> "$env_file"
            echo "   ✓ Added ${var_name}"
        fi
    fi
}

# Update common Orpheus configuration from environment variables
[ -n "$ORPHEUS_API_URL" ] && update_env_var "ORPHEUS_API_URL" "$ORPHEUS_API_URL"
[ -n "$ORPHEUS_API_TIMEOUT" ] && update_env_var "ORPHEUS_API_TIMEOUT" "$ORPHEUS_API_TIMEOUT"
[ -n "$ORPHEUS_MAX_TOKENS" ] && update_env_var "ORPHEUS_MAX_TOKENS" "$ORPHEUS_MAX_TOKENS"
[ -n "$ORPHEUS_TEMPERATURE" ] && update_env_var "ORPHEUS_TEMPERATURE" "$ORPHEUS_TEMPERATURE"
[ -n "$ORPHEUS_TOP_P" ] && update_env_var "ORPHEUS_TOP_P" "$ORPHEUS_TOP_P"
[ -n "$ORPHEUS_SAMPLE_RATE" ] && update_env_var "ORPHEUS_SAMPLE_RATE" "$ORPHEUS_SAMPLE_RATE"
[ -n "$ORPHEUS_MODEL_NAME" ] && update_env_var "ORPHEUS_MODEL_NAME" "$ORPHEUS_MODEL_NAME"
[ -n "$ORPHEUS_PORT" ] && update_env_var "ORPHEUS_PORT" "$ORPHEUS_PORT"
[ -n "$ORPHEUS_HOST" ] && update_env_var "ORPHEUS_HOST" "$ORPHEUS_HOST"

# Update API keys from environment variables
[ -n "$OPENAI_API_KEY" ] && update_env_var "OPENAI_API_KEY" "$OPENAI_API_KEY"
[ -n "$ANTHROPIC_API_KEY" ] && update_env_var "ANTHROPIC_API_KEY" "$ANTHROPIC_API_KEY"
[ -n "$GROQ_API_KEY" ] && update_env_var "GROQ_API_KEY" "$GROQ_API_KEY"
[ -n "$TOGETHER_API_KEY" ] && update_env_var "TOGETHER_API_KEY" "$TOGETHER_API_KEY"

# Update AWS configuration from environment variables
[ -n "$AWS_ACCESS_KEY_ID" ] && update_env_var "AWS_ACCESS_KEY_ID" "$AWS_ACCESS_KEY_ID"
[ -n "$AWS_SECRET_ACCESS_KEY" ] && update_env_var "AWS_SECRET_ACCESS_KEY" "$AWS_SECRET_ACCESS_KEY"
[ -n "$AWS_REGION" ] && update_env_var "AWS_REGION" "$AWS_REGION"
[ -n "$S3_BUCKET" ] && update_env_var "S3_BUCKET" "$S3_BUCKET"

# Update worker configuration from environment variables
[ -n "$API_BASE_URL" ] && update_env_var "API_BASE_URL" "$API_BASE_URL"
[ -n "$TTS_SERVER_URL" ] && update_env_var "TTS_SERVER_URL" "$TTS_SERVER_URL"
[ -n "$MAX_WORKERS" ] && update_env_var "MAX_WORKERS" "$MAX_WORKERS"
[ -n "$WORKER_TIMEOUT" ] && update_env_var "WORKER_TIMEOUT" "$WORKER_TIMEOUT"
[ -n "$RETRY_ATTEMPTS" ] && update_env_var "RETRY_ATTEMPTS" "$RETRY_ATTEMPTS"
[ -n "$RETRY_DELAY" ] && update_env_var "RETRY_DELAY" "$RETRY_DELAY"

# Enable workers if AWS credentials are provided
if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [ -n "$S3_BUCKET" ]; then
    update_env_var "ENABLE_WORKERS" "true"
    echo "   ✓ Enabled workers (AWS credentials detected)"
fi

echo "✅ Environment configuration updated from Vast.ai template"

# Set user permissions for Docker
echo "👤 Setting up user permissions..."
export USER_ID=$(id -u)
export GROUP_ID=$(id -g)

# Prepare environment for existing docker-compose.yml
echo "🐳 Preparing Docker configuration for Vast.ai..."

# Set required environment variables for docker-compose.yml
export USER_ID=$(id -u)
export GROUP_ID=$(id -g)

# Ensure required environment variables are set in .env for the existing docker-compose.yml
echo "⚙️ Configuring environment for existing docker-compose.yml..."

# Set default model name if not already configured
if ! grep -q "^ORPHEUS_MODEL_NAME=" .env; then
    echo "ORPHEUS_MODEL_NAME=Llama-3.2-3B-Instruct-Q4_K_M.gguf" >> .env
    echo "   ✓ Added default ORPHEUS_MODEL_NAME"
fi

# Set default max tokens if not already configured
if ! grep -q "^ORPHEUS_MAX_TOKENS=" .env; then
    echo "ORPHEUS_MAX_TOKENS=4096" >> .env
    echo "   ✓ Added default ORPHEUS_MAX_TOKENS"
fi

# Ensure models directory exists
mkdir -p ./models
echo "   ✓ Created models directory"

# Check available disk space before building
echo "💾 Checking available disk space..."
AVAILABLE_SPACE=$(df / | tail -1 | awk '{print $4}')
AVAILABLE_GB=$((AVAILABLE_SPACE / 1024 / 1024))
echo "   Available space: ${AVAILABLE_GB}GB"

if [ $AVAILABLE_GB -lt 10 ]; then
    echo "⚠️ Low disk space detected (${AVAILABLE_GB}GB available)"
    echo "🧹 Performing aggressive cleanup..."
    
    # Clean Docker system
    docker system prune -af --volumes 2>/dev/null || true
    
    # Clean package cache
    apt-get clean
    apt-get autoclean
    apt-get autoremove -y
    
    # Clean temporary files
    rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
    rm -rf /var/cache/apt/archives/* 2>/dev/null || true
    
    # Clean logs
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
    
    # Check space again
    AVAILABLE_SPACE=$(df / | tail -1 | awk '{print $4}')
    AVAILABLE_GB=$((AVAILABLE_SPACE / 1024 / 1024))
    echo "   Available space after cleanup: ${AVAILABLE_GB}GB"
    
    if [ $AVAILABLE_GB -lt 8 ]; then
        echo "❌ Still insufficient disk space (${AVAILABLE_GB}GB). Need at least 8GB for PyTorch installation."
        echo "💡 Consider using a Vast.ai instance with more storage or try the CPU-only version."
        exit 1
    fi
fi

# STEP 5: Run the project using GPU docker-compose
echo "🚀 Step 5: Running the project using GPU docker-compose..."

# Check if GPU docker-compose file exists
if [ -f "docker-compose-gpu.yml" ]; then
    COMPOSE_FILE="docker-compose-gpu.yml"
    echo "✅ Using GPU docker-compose file: $COMPOSE_FILE"
elif [ -f "docker-compose.yml" ]; then
    COMPOSE_FILE="docker-compose.yml"
    echo "✅ Using default docker-compose file: $COMPOSE_FILE"
else
    echo "❌ No docker-compose file found!"
    exit 1
fi

# Build and start the Docker containers using GPU docker-compose
echo "🏗️ Building Docker images..."
# Disable BuildKit for compatibility with containerized environments like Vast.ai
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0

if [ "$COMPOSE_FILE" = "docker-compose-gpu.yml" ]; then
    /usr/local/bin/docker-compose-wrapper -f docker-compose-gpu.yml build --no-cache
else
    /usr/local/bin/docker-compose-wrapper build --no-cache
fi

echo "🚀 Starting Docker containers with GPU support..."
# Check if containers are already running
if [ "$COMPOSE_FILE" = "docker-compose-gpu.yml" ]; then
    if /usr/local/bin/docker-compose-wrapper -f docker-compose-gpu.yml ps | grep -q "Up"; then
        echo "🔄 Containers already running, recreating with latest images..."
        /usr/local/bin/docker-compose-wrapper -f docker-compose-gpu.yml up -d --force-recreate
    else
        echo "🚀 Starting containers for the first time..."
        /usr/local/bin/docker-compose-wrapper -f docker-compose-gpu.yml up -d
    fi
else
    if /usr/local/bin/docker-compose-wrapper ps | grep -q "Up"; then
        echo "🔄 Containers already running, recreating with latest images..."
        /usr/local/bin/docker-compose-wrapper up -d --force-recreate
    else
        echo "🚀 Starting containers for the first time..."
        /usr/local/bin/docker-compose-wrapper up -d
    fi
fi

# Create supervisor configuration for Docker container management
echo "👷 Setting up supervisor configuration..."
if [ "$COMPOSE_FILE" = "docker-compose-gpu.yml" ]; then
    cat > /etc/supervisor/conf.d/orpheus-docker.conf << 'EOF'
[program:orpheus-docker]
command=/usr/local/bin/docker-compose-wrapper -f docker-compose-gpu.yml up --no-recreate
directory=/workspace/narration-engine
user=root
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/orpheus-docker.err.log
stdout_logfile=/var/log/supervisor/orpheus-docker.out.log
environment=PATH="/usr/local/bin:/usr/bin:/bin"
stopasgroup=true
killasgroup=true
EOF
else
    cat > /etc/supervisor/conf.d/orpheus-docker.conf << 'EOF'
[program:orpheus-docker]
command=/usr/local/bin/docker-compose-wrapper up --no-recreate
directory=/workspace/narration-engine
user=root
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/orpheus-docker.err.log
stdout_logfile=/var/log/supervisor/orpheus-docker.out.log
environment=PATH="/usr/local/bin:/usr/bin:/bin"
stopasgroup=true
killasgroup=true
EOF
fi

# Create nginx configuration for reverse proxy
echo "🌐 Setting up nginx reverse proxy..."
cat > /etc/nginx/sites-available/orpheus << 'EOF'
server {
    listen 8000;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:5005;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Increase timeout for long TTS generations
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }
    
    # Serve static files directly from Docker volume
    location /static/ {
        alias /workspace/narration-engine/static/;
        expires 1d;
        add_header Cache-Control "public, immutable";
    }
    
    # Serve generated audio files from Docker volume
    location /outputs/ {
        alias /workspace/narration-engine/outputs/;
        expires 1h;
        add_header Cache-Control "public";
    }
}
EOF

# Enable nginx site
ln -sf /etc/nginx/sites-available/orpheus /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test nginx configuration
nginx -t

# Start services
echo "🎬 Starting services..."
service nginx start
service supervisor start

# Wait for Docker containers to be ready
echo "⏳ Waiting for Docker containers to start..."
for i in {1..60}; do
    if [ "$COMPOSE_FILE" = "docker-compose-gpu.yml" ]; then
        COMPOSE_CHECK=$(/usr/local/bin/docker-compose-wrapper -f docker-compose-gpu.yml ps | grep -q "Up" && echo "true" || echo "false")
    else
        COMPOSE_CHECK=$(/usr/local/bin/docker-compose-wrapper ps | grep -q "Up" && echo "true" || echo "false")
    fi
    
    if [ "$COMPOSE_CHECK" = "true" ]; then
        echo "✅ Docker containers are running"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "❌ Docker containers failed to start within timeout"
        if [ "$COMPOSE_FILE" = "docker-compose-gpu.yml" ]; then
            /usr/local/bin/docker-compose-wrapper -f docker-compose-gpu.yml logs
        else
            /usr/local/bin/docker-compose-wrapper logs
        fi
        exit 1
    fi
    sleep 5
done

# Wait for TTS server to be ready inside container
echo "⏳ Waiting for TTS server to be ready..."
for i in {1..30}; do
    if curl -s http://localhost:5005/v1/audio/voices > /dev/null 2>&1; then
        echo "✅ TTS server is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ TTS server failed to start within timeout"
        if [ "$COMPOSE_FILE" = "docker-compose-gpu.yml" ]; then
            /usr/local/bin/docker-compose-wrapper -f docker-compose-gpu.yml logs orpheus-fastapi
        else
            /usr/local/bin/docker-compose-wrapper logs orpheus-fastapi
        fi
        exit 1
    fi
    sleep 5
done

# Set up Vast.ai portal configuration
echo "🌐 Setting up Vast.ai portal..."
export VAST_CONTAINERLABEL="Orpheus-FastAPI TTS Server (Docker)"
export VAST_TCP_PORT_8000="Orpheus TTS Web Interface"

# Display service status
echo "📊 Service Status:"
supervisorctl status
if [ "$COMPOSE_FILE" = "docker-compose-gpu.yml" ]; then
    /usr/local/bin/docker-compose-wrapper -f docker-compose-gpu.yml ps
else
    /usr/local/bin/docker-compose-wrapper ps
fi
nginx -t && echo "✅ Nginx configuration is valid"

echo ""
echo "🎉 Orpheus-FastAPI Docker setup complete!"
echo ""
echo "📋 Service Information:"
echo "   • Docker Containers: orpheus-fastapi, llama-cpp-server (RUNNING)"
echo "   • TTS Server: http://localhost:5005 (inside container)"
echo "   • LLM Server: http://localhost:5006 (inside container)"
echo "   • Web Interface: http://localhost:8000 (via nginx)"
echo "   • API Documentation: http://localhost:8000/docs"
echo "   • Docker Compose File: $COMPOSE_FILE"
echo ""
echo "🔧 Management Commands:"
echo "   • Check all status: supervisorctl status"
if [ "$COMPOSE_FILE" = "docker-compose-gpu.yml" ]; then
    echo "   • Check Docker: docker-compose -f docker-compose-gpu.yml ps"
    echo "   • View TTS logs: docker-compose -f docker-compose-gpu.yml logs -f"
    echo "   • Restart container: docker-compose -f docker-compose-gpu.yml restart"
    echo "   • Enter container: docker-compose -f docker-compose-gpu.yml exec orpheus-fastapi bash"
else
    echo "   • Check Docker: docker-compose ps"
    echo "   • View TTS logs: docker-compose logs -f"
    echo "   • Restart container: docker-compose restart"
    echo "   • Enter container: docker-compose exec orpheus-fastapi bash"
fi
echo ""
echo "⚠️  Important Notes:"
echo "   • TTS server runs inside Docker container with GPU acceleration"
echo "   • Environment variables from Vast.ai template are automatically applied"
echo "   • Access via Vast.ai portal on port 8000"
echo "   • TTS server starts automatically on boot"
echo ""
echo "🔑 Next Steps:"
echo "   • Test the setup: curl http://localhost:5005/v1/audio/voices"
echo "   • Access web interface: http://localhost:8000"
echo "   • Configure additional API keys in .env if needed"
echo ""
