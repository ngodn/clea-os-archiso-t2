#!/bin/bash
# Unified T2 Arch ISO Build System
# 
# This script handles everything:
# 1. Clones/updates linux-t2-clea repository
# 2. Builds all required T2 kernels
# 3. Creates local repository
# 4. Builds ISO variants
#
# Original T2 ISO by Noa Himesaka
# Unified build system by ngodn (eins0fx) <https://github.com/ngodn>

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHISO_DIR="$SCRIPT_DIR/archiso"
OUTPUT_DIR="$SCRIPT_DIR/out"
LOG_DIR="$SCRIPT_DIR/build-logs"
KERNEL_REPO_URL="https://github.com/ngodn/linux-t2-clea.git"
KERNEL_BUILD_DIR="$SCRIPT_DIR/linux-t2-clea"
LOCAL_REPO_DIR="$SCRIPT_DIR/local-repo"
BUILD_VARIANTS=("default" "lts" "xanmod" "xanmod-lts" "liquorix")
CLEAN_BUILD=${CLEAN_BUILD:-false}
VERBOSE=${VERBOSE:-false}
SKIP_KERNEL_BUILD=${SKIP_KERNEL_BUILD:-false}

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

# Create necessary directories
setup_directories() {
    mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$LOCAL_REPO_DIR"
    log_info "Created build directories"
}

# Check system requirements
check_requirements() {
    local required_commands=("mkarchiso" "sudo" "git" "curl" "makepkg" "repo-add")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        echo "Please install: sudo pacman -S archiso git curl base-devel"
        return 1
    fi
    
    # Check available disk space (require at least 30GB)
    local available_space=$(df "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    local required_space=$((30 * 1024 * 1024)) # 30GB in KB
    
    if [[ $available_space -lt $required_space ]]; then
        log_warning "Low disk space. Available: $(($available_space / 1024 / 1024))GB, Recommended: 30GB+"
    fi
    
    # Check if running as root or with sudo access
    if [[ $EUID -eq 0 ]]; then
        log_warning "Running as root - this is not recommended"
    elif ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo access for mkarchiso"
    fi
    
    log_success "System requirements check passed"
}

# Clone or update kernel repository
setup_kernel_repository() {
    log_info "Setting up kernel repository..."
    
    if [[ -d "$KERNEL_BUILD_DIR" ]]; then
        if [[ "$CLEAN_BUILD" == "true" ]]; then
            log_info "Cleaning existing kernel repository..."
            rm -rf "$KERNEL_BUILD_DIR"
        else
            log_info "Updating existing kernel repository..."
            cd "$KERNEL_BUILD_DIR"
            
            # Clean any local changes
            git reset --hard HEAD
            git clean -fdx
            
            # Update to latest
            if ! git pull origin main; then
                log_warning "Failed to update repository, will re-clone..."
                cd "$SCRIPT_DIR"
                rm -rf "$KERNEL_BUILD_DIR"
            else
                log_success "Repository updated successfully"
                return 0
            fi
        fi
    fi
    
    # Clone repository
    log_info "Cloning kernel repository from $KERNEL_REPO_URL..."
    if ! git clone "$KERNEL_REPO_URL" "$KERNEL_BUILD_DIR"; then
        log_error "Failed to clone kernel repository"
        return 1
    fi
    
    log_success "Kernel repository ready at $KERNEL_BUILD_DIR"
}

# Get kernel variant configuration mapping
get_kernel_config() {
    local variant="$1"
    
    case "$variant" in
        "default")
            echo "linux-t2"
            ;;
        "lts")
            echo "linux-t2-lts"
            ;;
        "xanmod")
            echo "linux-t2-xanmod"
            ;;
        "xanmod-lts")
            echo "linux-t2-xanmod-lts"
            ;;
        "liquorix")
            echo "linux-t2-liquorix"
            ;;
        *)
            log_error "Unknown variant: $variant"
            return 1
            ;;
    esac
}

# Build T2 kernels
build_kernels() {
    if [[ "$SKIP_KERNEL_BUILD" == "true" ]]; then
        log_info "Skipping kernel build (SKIP_KERNEL_BUILD=true)"
        return 0
    fi
    
    log_info "Building T2 kernel variants..."
    
    cd "$KERNEL_BUILD_DIR"
    
    # Check if build-all.sh exists
    if [[ ! -f "build-all.sh" ]]; then
        log_error "build-all.sh not found in $KERNEL_BUILD_DIR"
        return 1
    fi
    
    # Make sure it's executable
    chmod +x build-all.sh
    
    # Set up build options
    local build_opts=()
    if [[ "$CLEAN_BUILD" == "true" ]]; then
        build_opts+=("--clean")
    fi
    if [[ "$VERBOSE" == "true" ]]; then
        build_opts+=("--verbose")
    fi
    
    # Build all kernel variants
    log_info "Running kernel build system..."
    local kernel_build_log="$LOG_DIR/kernel-build.log"
    
    if [[ "$VERBOSE" == "true" ]]; then
        if ! ./build-all.sh "${build_opts[@]}" 2>&1 | tee "$kernel_build_log"; then
            log_error "Kernel build failed. Check log: $kernel_build_log"
            return 1
        fi
    else
        if ! ./build-all.sh "${build_opts[@]}" >"$kernel_build_log" 2>&1; then
            log_error "Kernel build failed. Check log: $kernel_build_log"
            return 1
        fi
    fi
    
    log_success "All kernel variants built successfully"
    
    # Copy built packages to local repository
    setup_local_repository
    
    return 0
}

# Show usage
show_usage() {
    echo "Unified T2 Arch ISO Build System"
    echo "==============================="
    echo "Builds T2 kernels from source, then creates ISO variants"
    echo
    echo "Usage: $0 [OPTIONS] [VARIANT]"
    echo
    echo "Options:"
    echo "  -c, --clean           Clean all previous builds and repositories"
    echo "  -v, --verbose         Verbose output with detailed logging"
    echo "  -s, --skip-kernels    Skip kernel building (use existing packages)"
    echo "  --clean-all           Clean everything and exit"
    echo "  -h, --help            Show this help"
    echo
    echo "Variants:"
    echo "  default               Mainline T2 kernel (linux-t2)"
    echo "  lts                   LTS T2 kernel (linux-t2-lts)"
    echo "  xanmod                XanMod T2 kernel (linux-t2-xanmod)"
    echo "  xanmod-lts            XanMod LTS T2 kernel (linux-t2-xanmod-lts)"
    echo "  liquorix              Liquorix T2 kernel (linux-t2-liquorix)"
    echo "  all                   Build all variants (default)"
    echo
    echo "Examples:"
    echo "  $0                         # Build everything (kernels + all ISOs)"
    echo "  $0 xanmod                  # Build kernels then XanMod ISO only"
    echo "  $0 --clean --verbose       # Clean build with verbose output"
    echo "  $0 -s lts                  # Skip kernel build, use existing packages"
    echo "  $0 --clean-all             # Clean everything and exit"
    echo
    echo "Repository:"
    echo "  Kernel source: $KERNEL_REPO_URL"
    echo "  Local clone:   $KERNEL_BUILD_DIR"
}

# Main function
main() {
    local build_variant="all"
    
    echo "Unified T2 Arch ISO Build System"
    echo "==============================="
    echo "Builds T2 kernels from source, then creates ISO variants"
    echo
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--clean)
                CLEAN_BUILD=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -s|--skip-kernels)
                SKIP_KERNEL_BUILD=true
                shift
                ;;
            --clean-all)
                log_info "Cleaning all build artifacts..."
                rm -rf "$OUTPUT_DIR" "$LOG_DIR" "$LOCAL_REPO_DIR" "$KERNEL_BUILD_DIR"
                find "$SCRIPT_DIR" -maxdepth 1 -name "archiso-*" -type d -exec rm -rf {} \;
                log_success "All build artifacts cleaned"
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            default|lts|xanmod|xanmod-lts|liquorix|all)
                build_variant="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Setup directories and check requirements
    setup_directories
    check_requirements
    
    log_info "Build variant: $build_variant"
    log_info "Clean build: $CLEAN_BUILD"
    log_info "Verbose: $VERBOSE"
    log_info "Skip kernel build: $SKIP_KERNEL_BUILD"
    log_info "Kernel repository: $KERNEL_REPO_URL"
    echo
    
    local start_time=$(date +%s)
    
    # Step 1: Setup kernel repository
    if ! setup_kernel_repository; then
        log_error "Failed to setup kernel repository"
        exit 1
    fi
    
    # Step 2: Build T2 kernels
    if ! build_kernels; then
        log_error "Kernel building failed"
        exit 1
    fi
    
    # For now, just show success message
    # TODO: Add ISO building functionality
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    log_success "Kernel build completed in ${total_time}s"
    log_info "ISO building functionality will be added next"
    
    exit 0
}

# Run main function with all arguments
main "$@"
