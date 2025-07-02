#!/bin/bash
#
# Setup script for Orpheus Worker System
# Cross-platform shell script for Ubuntu and macOS
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Emojis (fallback to text if not supported)
if [[ "$OSTYPE" == "darwin"* ]]; then
    ROCKET="🚀"
    CHECK="✅"
    WARNING="⚠️"
    ERROR="❌"
    PACKAGE="📦"
    GEAR="🔧"
    COMPUTER="🖥️"
    LOCATION="📍"
    CLONE="🔄"
    TRASH="🗑️"
    NOTE="📝"
else
    ROCKET="[SETUP]"
    CHECK="[OK]"
    WARNING="[WARN]"
    ERROR="[ERROR]"
    PACKAGE="[INSTALL]"
    GEAR="[CONFIG]"
    COMPUTER="[OS]"
    LOCATION="[PLATFORM]"
    CLONE="[CLONE]"
    TRASH="[REMOVE]"
    NOTE="[NOTE]"
fi

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    case $status in
        "success")
            echo -e "${GREEN}${CHECK} ${message}${NC}"
            ;;
        "error")
            echo -e "${RED}${ERROR} ${message}${NC}"
            ;;
        "warning")
            echo -e "${YELLOW}${WARNING} ${message}${NC}"
            ;;
        "info")
            echo -e "${BLUE}${message}${NC}"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Function to detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "ubuntu"
    else
        echo "unknown"
    fi
}

# Function to check if git is installed
check_git_installation() {
    if command -v git &> /dev/null; then
        return 0
    else
        local os_type=$(detect_os)
        print_status "error" "Git is not installed"
        
        if [[ "$os_type" == "ubuntu" ]]; then
            echo "   To install git on Ubuntu/Debian:"
            echo "   sudo apt update && sudo apt install git"
        elif [[ "$os_type" == "macos" ]]; then
            echo "   To install git on macOS:"
            echo "   - Install Xcode Command Line Tools: xcode-select --install"
            echo "   - Or install via Homebrew: brew install git"
        else
            echo "   Please install git for your operating system"
        fi
        
        return 1
    fi
}

# Function to clone NarrationEngine repository
clone_narration_engine() {
    local repo_url="https://github.com/momentumos/NarrationEngine"
    local repo_name="NarrationEngine"
    
    echo -e "${BLUE}${CLONE} Cloning NarrationEngine repository...${NC}"
    
    # Check if git is installed
    if ! check_git_installation; then
        return 1
    fi
    
    # Check if repository already exists
    if [[ -d "$repo_name" ]]; then
        print_status "warning" "$repo_name directory already exists"
        read -p "Do you want to remove it and clone fresh? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}${TRASH} Removing existing $repo_name directory...${NC}"
            if ! rm -rf "$repo_name"; then
                print_status "error" "Permission denied removing $repo_name"
                echo "   Try running with sudo or check file permissions"
                return 1
            fi
        else
            print_status "info" "${NOTE} Keeping existing $repo_name directory"
            return 0
        fi
    fi
    
    # Clone the repository
    if git clone "$repo_url"; then
        print_status "success" "Successfully cloned $repo_name"
        
        # Check if Worker directory exists in the cloned repo
        local worker_path="$repo_name/Worker"
        if [[ -d "$worker_path" ]]; then
            print_status "success" "Found Worker directory in $repo_name"
        else
            print_status "warning" "Worker directory not found in $repo_name"
        fi
        
        return 0
    else
        print_status "error" "Failed to clone repository"
        echo "   Check your internet connection and repository access"
        return 1
    fi
}

# Function to check Python version
check_python_version() {
    local python_cmd=""
    
    # Try different Python commands
    if command -v python3 &> /dev/null; then
        python_cmd="python3"
    elif command -v python &> /dev/null; then
        python_cmd="python"
    else
        print_status "error" "Python is not installed"
        local os_type=$(detect_os)
        if [[ "$os_type" == "ubuntu" ]]; then
            echo "   Install Python: sudo apt install python3 python3-pip"
        elif [[ "$os_type" == "macos" ]]; then
            echo "   Install Python: brew install python"
        fi
        return 1
    fi
    
    # Check Python version
    local python_version=$($python_cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    local major_version=$(echo $python_version | cut -d. -f1)
    local minor_version=$(echo $python_version | cut -d. -f2)
    
    if [[ $major_version -lt 3 ]] || [[ $major_version -eq 3 && $minor_version -lt 8 ]]; then
        print_status "error" "Python 3.8 or higher is required"
        echo "   Current version: $python_version"
        return 1
    fi
    
    print_status "success" "Python version: $python_version"
    return 0
}

# Function to install requirements
install_requirements() {
    echo -e "${BLUE}${PACKAGE} Installing requirements...${NC}"
    
    # Check for requirements.txt in multiple locations
    local requirements_file=""
    if [[ -f "requirements.txt" ]]; then
        requirements_file="requirements.txt"
    elif [[ -f "NarrationEngine/Worker/requirements.txt" ]]; then
        requirements_file="NarrationEngine/Worker/requirements.txt"
    else
        print_status "warning" "requirements.txt not found in current directory or NarrationEngine/Worker/, skipping package installation"
        return 0
    fi
    
    print_status "info" "Using requirements file: $requirements_file"
    
    # Determine Python command
    local python_cmd=""
    if command -v python3 &> /dev/null; then
        python_cmd="python3"
    elif command -v python &> /dev/null; then
        python_cmd="python"
    else
        print_status "error" "Python is not available"
        return 1
    fi
    
    # Try to upgrade pip first
    $python_cmd -m pip install --upgrade pip &> /dev/null
    
    # Install requirements
    if $python_cmd -m pip install -r "$requirements_file"; then
        print_status "success" "Requirements installed successfully"
        return 0
    else
        print_status "error" "Failed to install requirements"
        
        # Provide OS-specific troubleshooting
        local os_type=$(detect_os)
        if [[ "$os_type" == "ubuntu" ]]; then
            echo "   Try installing python3-pip: sudo apt install python3-pip"
            echo "   Or use virtual environment: python3 -m venv venv && source venv/bin/activate"
        elif [[ "$os_type" == "macos" ]]; then
            echo "   Try installing pip via Homebrew: brew install python"
            echo "   Or use virtual environment: python3 -m venv venv && source venv/bin/activate"
        fi
        
        return 1
    fi
}

# Function to update environment variable in .env file
update_env_var() {
    local env_file_path=$1
    local var_name=$2
    local var_value=$3
    
    if [[ ! -f "$env_file_path" ]]; then
        return 1
    fi
    
    # Check if variable exists and update it
    if grep -q "^${var_name}=" "$env_file_path"; then
        # Variable exists, update it
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS sed syntax
            sed -i '' "s/^${var_name}=.*/${var_name}=${var_value}/" "$env_file_path"
        else
            # Linux sed syntax
            sed -i "s/^${var_name}=.*/${var_name}=${var_value}/" "$env_file_path"
        fi
    else
        # Variable doesn't exist, add it
        echo "${var_name}=${var_value}" >> "$env_file_path"
    fi
    
    return 0
}

# Function to setup environment file
setup_env_file() {
    local env_file=".env"
    local env_example=""
    
    # Find .env.example in multiple locations
    if [[ -f ".env.example" ]]; then
        env_example=".env.example"
    elif [[ -f "Worker/.env.example" ]]; then
        env_example="Worker/.env.example"
        env_file="Worker/.env"
    elif [[ -f "NarrationEngine/Worker/.env.example" ]]; then
        env_example="NarrationEngine/Worker/.env.example"
        env_file="NarrationEngine/Worker/.env"
    else
        print_status "error" ".env.example not found in current directory, Worker/, or NarrationEngine/Worker/"
        return 1
    fi
    
    print_status "info" "Using .env.example file: $env_example"
    print_status "info" "Target .env file: $env_file"
    
    # Always copy .env.example to .env (overwrite if exists)
    if [[ -f "$env_file" ]]; then
        print_status "warning" "$env_file already exists - will be overwritten with values from $env_example"
    fi
    
    # Create fresh copy from example
    if cp "$env_example" "$env_file"; then
        print_status "success" "Copied $env_example to $env_file"
    else
        print_status "error" "Failed to copy $env_example to $env_file"
        return 1
    fi
    
    # Update environment variables from system environment
    echo -e "${BLUE}${GEAR} Updating .env file with system environment variables...${NC}"
    local updated_vars=()
    
    # Define environment variables to check and update
    local env_vars_to_check=(
        "ORPHEUS_API_URL"
        "ORPHEUS_API_TIMEOUT"
        "ORPHEUS_MAX_TOKENS"
        "ORPHEUS_TEMPERATURE"
        "ORPHEUS_TOP_P"
        "ORPHEUS_SAMPLE_RATE"
        "ORPHEUS_MODEL_NAME"
        "ORPHEUS_PORT"
        "ORPHEUS_HOST"
        "OPENAI_API_KEY"
        "ANTHROPIC_API_KEY"
        "GROQ_API_KEY"
        "TOGETHER_API_KEY"
        "API_BASE_URL"
        "SERVER_TO_SERVER_API_KEY"
        "TTS_SERVER_URL"
        "AWS_ACCESS_KEY_ID"
        "AWS_SECRET_ACCESS_KEY"
        "AWS_REGION"
        "S3_BUCKET"
        "MAX_WORKERS"
        "WORKER_TIMEOUT"
        "RETRY_ATTEMPTS"
        "RETRY_DELAY"
        "DISCORD_WEBHOOK_URL"
        "USE_RANDOM_VOICE"
        "WORKER_PHONE"
        "WORKER_COUNTRY"
        "WORKER_VERIFICATION_CODE"
        "WORKER_DEVICE_ID"
        "WORKER_USER_AGENT"
        "WORKER_VOICE"
    )
    
    for var_name in "${env_vars_to_check[@]}"; do
        local var_value="${!var_name}"
        if [[ -n "$var_value" ]]; then
            if update_env_var "$env_file" "$var_name" "$var_value"; then
                updated_vars+=("$var_name")
            fi
        fi
    done
    
    if [[ ${#updated_vars[@]} -gt 0 ]]; then
        print_status "success" "Updated ${#updated_vars[@]} environment variables from system:"
        for var in "${updated_vars[@]}"; do
            # Don't print sensitive values
            if [[ "$var" == *"KEY"* ]] || [[ "$var" == *"SECRET"* ]] || [[ "$var" == *"TOKEN"* ]]; then
                echo "   - $var=***"
            else
                echo "   - $var=${!var}"
            fi
        done
    else
        print_status "info" "${NOTE} No system environment variables found to update"
        echo "   Please set environment variables or edit .env file with your actual configuration values"
    fi
    
    return 0
}

# Function to create outputs directory
create_outputs_directory() {
    local outputs_dir="outputs"
    if [[ ! -d "$outputs_dir" ]]; then
        mkdir -p "$outputs_dir"
        print_status "success" "Created $outputs_dir directory"
    else
        print_status "success" "$outputs_dir directory already exists"
    fi
}

# Main function
main() {
    echo -e "${BLUE}${ROCKET} Orpheus Worker System Setup${NC}"
    echo "========================================"
    
    # Detect and display OS information
    local os_type=$(detect_os)
    echo -e "${BLUE}${COMPUTER} Detected OS: $(echo $os_type | tr '[:lower:]' '[:upper:]')${NC}"
    echo -e "${BLUE}${LOCATION} Platform: $(uname -s) $(uname -r)${NC}"
    echo
    
    # Clone NarrationEngine repository first
    if ! clone_narration_engine; then
        exit 1
    fi
    
    # Check Python version
    if ! check_python_version; then
        exit 1
    fi
    
    # Install requirements
    if ! install_requirements; then
        exit 1
    fi
    
    # Setup environment file
    if ! setup_env_file; then
        exit 1
    fi
    
    # Create outputs directory
    create_outputs_directory
    
    echo
    echo "========================================"
    print_status "success" "Setup completed successfully!"
    echo
    echo -e "${BLUE}${NOTE} Next steps:${NC}"
    echo "   1. Edit .env file with your actual configuration"
    echo "   2. Run: python run_workers.py"
    echo "   3. Check NarrationEngine/Worker directory for additional worker files"
    echo
    echo -e "${YELLOW}${WARNING} Required environment variables:${NC}"
    echo "   - API_BASE_URL"
    echo "   - SERVER_TO_SERVER_API_KEY"
    echo "   - AWS_ACCESS_KEY_ID"
    echo "   - AWS_SECRET_ACCESS_KEY"
    echo "   - S3_BUCKET"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
