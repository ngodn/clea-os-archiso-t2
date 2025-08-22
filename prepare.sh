#!/bin/bash
# Enhanced T2 Arch ISO Preparation Script
# 
# Original T2 ISO by Noa Himesaka
# Enhanced preparation system by ngodn (eins0fx) <https://github.com/ngodn>

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running on Arch Linux
check_arch_linux() {
    if ! command -v pacman >/dev/null 2>&1; then
        log_error "This script requires Arch Linux (pacman not found)"
        return 1
    fi
    
    if [[ ! -f /etc/arch-release ]]; then
        log_warning "Not running on Arch Linux - some features may not work"
    fi
    
    log_success "Arch Linux detected"
}

# Check system requirements
check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check available disk space (need at least 50GB for all variants)
    local available_space=$(df . | awk 'NR==2 {print $4}')
    local required_space=$((50 * 1024 * 1024)) # 50GB in KB
    
    if [[ $available_space -lt $required_space ]]; then
        log_warning "Low disk space. Available: $(($available_space / 1024 / 1024))GB, Recommended: 50GB+"
        echo "This may cause build failures for multiple ISO variants."
    else
        log_success "Sufficient disk space available: $(($available_space / 1024 / 1024))GB"
    fi
    
    # Check memory
    local total_memory=$(free -m | awk 'NR==2{print $2}')
    if [[ $total_memory -lt 4096 ]]; then
        log_warning "Low memory: ${total_memory}MB. Recommended: 4GB+ for ISO builds"
    else
        log_success "Sufficient memory: ${total_memory}MB"
    fi
    
    # Check CPU cores
    local cpu_cores=$(nproc)
    log_info "CPU cores: $cpu_cores (more cores = faster builds)"
}

# Install required packages
install_dependencies() {
    log_info "Installing required packages..."
    
    local packages=(
        "archiso"           # Core archiso package
        "wget"              # Download utility
        "git"               # Version control
        "curl"              # HTTP client
        "jq"                # JSON processor
        "rsync"             # File synchronization
        "squashfs-tools"    # Filesystem tools
    )
    
    local missing_packages=()
    
    # Check which packages are missing
    for package in "${packages[@]}"; do
        if ! pacman -Qi "$package" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done
    
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_success "All required packages are already installed"
    else
        log_info "Installing missing packages: ${missing_packages[*]}"
        
        if ! sudo pacman --noconfirm --needed -S "${missing_packages[@]}"; then
            log_error "Failed to install required packages"
            return 1
        fi
        
        log_success "Successfully installed all required packages"
    fi
}

# Verify archiso installation
verify_archiso() {
    log_info "Verifying archiso installation..."
    
    if ! command -v mkarchiso >/dev/null 2>&1; then
        log_error "mkarchiso command not found - archiso installation failed"
        return 1
    fi
    
    # Check archiso version
    local archiso_version=$(mkarchiso -h 2>&1 | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    log_success "archiso verified - version: $archiso_version"
}

# Setup build environment
setup_build_environment() {
    log_info "Setting up build environment..."
    
    # Create necessary directories
    local directories=("out" "build-logs" "work")
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_info "Created directory: $dir"
        fi
    done
    
    # Set up proper permissions
    if [[ -d "out" ]]; then
        chmod 755 out
    fi
    
    log_success "Build environment setup complete"
}

# Check for enhanced build script
check_enhanced_build() {
    if [[ -f "build-enhanced.sh" ]]; then
        log_success "Enhanced build system detected"
        echo
        log_info "You can now use the enhanced build system:"
        echo "  ${BOLD}./build-enhanced.sh${NC}                 # Build all variants"
        echo "  ${BOLD}./build-enhanced.sh xanmod${NC}          # Build specific variant"  
        echo "  ${BOLD}./build-enhanced.sh --clean --verbose${NC} # Clean build with logs"
        echo
    else
        log_warning "Enhanced build script not found"
        log_info "Using traditional build method:"
        echo "  ${BOLD}./build.sh${NC}                         # Build default ISO"
    fi
}

# Validate configuration
validate_configuration() {
    log_info "Validating configuration..."
    
    # Check if archiso directory exists
    if [[ ! -d "archiso" ]]; then
        log_error "archiso configuration directory not found"
        log_info "Make sure you're in the correct directory"
        return 1
    fi
    
    # Check essential files
    local essential_files=(
        "archiso/profiledef.sh"
        "archiso/packages.x86_64"
        "archiso/pacman.conf"
    )
    
    local missing_files=()
    for file in "${essential_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_error "Missing essential files:"
        printf '  - %s\n' "${missing_files[@]}"
        return 1
    fi
    
    # Check if T2 packages are in the package list
    if ! grep -q "linux-t2" archiso/packages.x86_64; then
        log_warning "T2 kernel packages not found in package list"
    else
        local t2_kernels=$(grep "linux-t2" archiso/packages.x86_64 | wc -l)
        log_success "Found $t2_kernels T2 kernel variants in package list"
    fi
    
    log_success "Configuration validation complete"
}

# Show system information
show_system_info() {
    echo
    log_info "System Information:"
    echo "  OS: $(uname -a)"
    echo "  CPU: $(nproc) cores"
    echo "  Memory: $(free -h | grep Mem | awk '{print $2}') total"
    echo "  Disk Space: $(df -h . | awk 'NR==2 {print $4}') available"
    echo "  User: $(whoami)"
    echo
}

# Main preparation function
main() {
    echo "${BOLD}Enhanced T2 Arch ISO Preparation${NC}"
    echo "================================="
    echo
    
    # Parse command line arguments
    local verbose=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                verbose=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo "Options:"
                echo "  -v, --verbose   Show detailed system information"
                echo "  -h, --help      Show this help"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Show system info if verbose
    if [[ "$verbose" == "true" ]]; then
        show_system_info
    fi
    
    # Run preparation steps
    if check_arch_linux && \
       check_system_requirements && \
       install_dependencies && \
       verify_archiso && \
       setup_build_environment && \
       validate_configuration; then
        
        echo
        log_success "T2 Arch ISO preparation completed successfully!"
        echo
        check_enhanced_build
        
        echo
        log_info "Next steps:"
        echo "1. Review the archiso configuration in ./archiso/"
        echo "2. Build ISO(s) using the build script"
        echo "3. Test the built ISO on T2 Mac hardware"
        echo
        
        exit 0
    else
        echo
        log_error "Preparation failed. Please resolve the issues above."
        exit 1
    fi
}

# Run main function with all arguments
main "$@"
