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

# Legacy build_kernels function - kept for compatibility
build_kernels() {
    log_warning "build_kernels() is deprecated, use build_kernel_variants() instead"
    return 0
}

# Build specific kernel variants based on build_variant
build_kernel_variants() {
    local build_variant="$1"
    
    if [[ "$SKIP_KERNEL_BUILD" == "true" ]]; then
        log_info "Skipping kernel build (SKIP_KERNEL_BUILD=true)"
        return 0
    fi
    
    log_info "Building T2 kernel variants for: $build_variant"
    
    cd "$KERNEL_BUILD_DIR"
    
    # Determine which variants to build
    local variants_to_build=()
    if [[ "$build_variant" == "all" ]]; then
        variants_to_build=("${BUILD_VARIANTS[@]}")
        log_info "Building all kernel variants: ${BUILD_VARIANTS[*]}"
    else
        variants_to_build=("$build_variant")
        log_info "Building single kernel variant: $build_variant"
    fi
    
    # Build each variant
    for variant in "${variants_to_build[@]}"; do
        if ! build_single_kernel_variant "$variant"; then
            log_error "Failed to build kernel variant: $variant"
            return 1
        fi
    done
    
    log_success "Kernel build completed successfully"
    return 0
}

# Build a single kernel variant using makepkg
build_single_kernel_variant() {
    local variant="$1"
    local kernel_build_log="$LOG_DIR/kernel-build-$variant.log"
    
    log_info "Building $variant kernel variant..."
    
    # Get the correct PKGBUILD file
    local pkgbuild_file
    case "$variant" in
        "default")
            pkgbuild_file="PKGBUILD"
            ;;
        *)
            pkgbuild_file="PKGBUILD-$variant"
            ;;
    esac
    
    # Check if PKGBUILD exists
    if [[ ! -f "$pkgbuild_file" ]]; then
        log_error "PKGBUILD file not found: $pkgbuild_file"
        return 1
    fi
    
    # Set up build options
    local makepkg_opts=("-s" "--noconfirm")
    if [[ "$CLEAN_BUILD" == "true" ]]; then
        makepkg_opts+=("-c")
    fi
    
    # Build the kernel variant
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Building $variant kernel (verbose mode)"
        if ! makepkg -p "$pkgbuild_file" "${makepkg_opts[@]}" 2>&1 | tee "$kernel_build_log"; then
            log_error "Kernel build failed for $variant. Check log: $kernel_build_log"
            return 1
        fi
    else
        log_info "Building $variant kernel (quiet mode, logging to $kernel_build_log)"
        if ! makepkg -p "$pkgbuild_file" "${makepkg_opts[@]}" >"$kernel_build_log" 2>&1; then
            log_error "Kernel build failed for $variant. Check log: $kernel_build_log"
            return 1
        fi
    fi
    
    log_success "Successfully built $variant kernel variant"
    
    # List generated packages
    local packages=(*.pkg.tar.*)
    if [[ ${#packages[@]} -gt 0 && "${packages[0]}" != "*.pkg.tar.*" ]]; then
        log_info "Generated packages for $variant:"
        for pkg in "${packages[@]}"; do
            local pkg_size=$(du -h "$pkg" | cut -f1)
            log_info "  - $pkg ($pkg_size)"
        done
    fi
    
    return 0
}

# Setup local repository with built T2 packages
setup_local_repository() {
    log_info "Setting up local repository with built T2 packages..."
    
    # Create local repository structure
    mkdir -p "$LOCAL_REPO_DIR"
    
    # Find all built packages in kernel build directory
    local built_packages=()
    if [[ -d "$KERNEL_BUILD_DIR" ]]; then
        # Look for built packages (*.pkg.tar.zst files)
        while IFS= read -r -d '' package; do
            built_packages+=("$package")
        done < <(find "$KERNEL_BUILD_DIR" -name "*.pkg.tar.zst" -print0 2>/dev/null)
    fi
    
    # Also check current script directory for packages (fallback)
    if [[ ${#built_packages[@]} -eq 0 ]]; then
        while IFS= read -r -d '' package; do
            built_packages+=("$package")
        done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "*.pkg.tar.zst" -print0 2>/dev/null)
    fi
    
    # Also check for packages in nested linux-t2-clea directory (common case)
    if [[ ${#built_packages[@]} -eq 0 ]]; then
        while IFS= read -r -d '' package; do
            built_packages+=("$package")
        done < <(find "$SCRIPT_DIR/linux-t2-clea" -maxdepth 1 -name "*.pkg.tar.zst" -print0 2>/dev/null)
    fi
    
    # Also check current working directory (in case script is run from different location)
    if [[ ${#built_packages[@]} -eq 0 ]]; then
        while IFS= read -r -d '' package; do
            built_packages+=("$package")
        done < <(find "$(pwd)" -maxdepth 1 -name "*.pkg.tar.zst" -print0 2>/dev/null)
    fi
    
    if [[ ${#built_packages[@]} -eq 0 ]]; then
        log_warning "No built T2 packages found in $KERNEL_BUILD_DIR"
        log_warning "Also checked $SCRIPT_DIR and $SCRIPT_DIR/linux-t2-clea"
        log_info "Make sure kernel build completed successfully"
        log_info "Current working directory: $(pwd)"
        log_info "Script directory: $SCRIPT_DIR"
        
        # Additional debug: search more aggressively
        log_info "Searching for packages more broadly..."
        local all_packages=()
        while IFS= read -r -d '' package; do
            all_packages+=("$package")
        done < <(find "$SCRIPT_DIR" -name "*.pkg.tar.zst" -print0 2>/dev/null)
        
        if [[ ${#all_packages[@]} -gt 0 ]]; then
            log_info "Found packages in script directory tree:"
            for pkg in "${all_packages[@]}"; do
                log_info "  - $pkg"
            done
            built_packages=("${all_packages[@]}")
        else
            log_error "No T2 packages found anywhere. Kernel build may have failed."
            return 1
        fi
    fi
    
    log_info "Found ${#built_packages[@]} built T2 packages"
    
    # Copy packages to local repository
    for package in "${built_packages[@]}"; do
        local package_name=$(basename "$package")
        log_info "Adding package: $package_name"
        cp "$package" "$LOCAL_REPO_DIR/"
    done
    
    # Create repository database
    cd "$LOCAL_REPO_DIR"
    
    # Verify packages exist in local repo
    local repo_packages=(*.pkg.tar.zst)
    if [[ ${#repo_packages[@]} -eq 0 || "${repo_packages[0]}" == "*.pkg.tar.zst" ]]; then
        log_error "No packages found in local repository directory: $LOCAL_REPO_DIR"
        return 1
    fi
    
    log_info "Creating repository database with ${#repo_packages[@]} packages:"
    for pkg in "${repo_packages[@]}"; do
        log_info "  - $(basename "$pkg")"
    done
    
    if ! repo-add clea-t2-local.db.tar.gz *.pkg.tar.zst; then
        log_error "Failed to create repository database"
        log_info "Repository directory contents:"
        ls -la "$LOCAL_REPO_DIR"
        return 1
    fi
    
    log_success "Local T2 repository created at $LOCAL_REPO_DIR"
    
    # Update archiso pacman.conf to include local repository
    update_archiso_pacman_config
    
    return 0
}

# Update archiso pacman.conf to include local repository
update_archiso_pacman_config() {
    local pacman_conf="$ARCHISO_DIR/pacman.conf"
    
    log_info "Configuring local repository in pacman.conf"
    log_info "Local repository path: $LOCAL_REPO_DIR"
    
    # Verify local repository exists and has packages
    if [[ ! -d "$LOCAL_REPO_DIR" ]]; then
        log_error "Local repository not found at $LOCAL_REPO_DIR"
        return 1
    fi
    
    local repo_packages=($(find "$LOCAL_REPO_DIR" -name "*.pkg.tar.zst" 2>/dev/null))
    if [[ ${#repo_packages[@]} -eq 0 ]]; then
        log_error "No packages found in local repository at $LOCAL_REPO_DIR"
        return 1
    fi
    
    log_info "Found ${#repo_packages[@]} packages in local repository"
    
    # Configure repository entry - mkarchiso can access host filesystem paths
    local local_repo_entry="[clea-t2-local]
Server = file://$LOCAL_REPO_DIR
SigLevel = Optional TrustAll"
    
    # Backup original pacman.conf if it doesn't exist
    if [[ ! -f "$pacman_conf.orig" ]]; then
        cp "$pacman_conf" "$pacman_conf.orig"
        log_info "Created backup of original pacman.conf"
    fi
    
    # Remove any existing local repository entry
    if grep -q "\[clea-t2-local\]" "$pacman_conf"; then
        log_info "Removing existing local repository configuration..."
        sed -i '/\[clea-t2-local\]/,/^$/d' "$pacman_conf"
    fi
    
    # Add local repository entry at the beginning (highest priority)
    # This ensures our custom kernel takes precedence over any conflicting packages
    local temp_file=$(mktemp)
    {
        echo "$local_repo_entry"
        echo ""
        cat "$pacman_conf"
    } > "$temp_file"
    mv "$temp_file" "$pacman_conf"
    
    log_success "Added local T2 repository to pacman.conf (highest priority)"
    
    # Verify the repository configuration
    log_info "Repository configuration in pacman.conf:"
    head -n 10 "$pacman_conf" | grep -A3 "\[clea-t2-local\]" || log_warning "Could not verify repository configuration"
    
    # Test repository access
    log_info "Testing repository database access..."
    local db_files=($(find "$LOCAL_REPO_DIR" -name "*.db*" 2>/dev/null))
    if [[ ${#db_files[@]} -eq 0 ]]; then
        log_error "No repository database files found in $LOCAL_REPO_DIR"
        return 1
    fi
    
    for db_file in "${db_files[@]}"; do
        log_info "  - $(basename "$db_file")"
    done
}

# Build ISO variants
build_isos() {
    local variant="$1"
    
    log_info "Building ISO variant(s): $variant"
    
    if [[ "$variant" == "all" ]]; then
        # Build all variants
        for v in "${BUILD_VARIANTS[@]}"; do
            if ! build_single_iso "$v"; then
                log_error "Failed to build $v ISO"
                return 1
            fi
        done
    else
        # Build single variant
        if ! build_single_iso "$variant"; then
            log_error "Failed to build $variant ISO"
            return 1
        fi
    fi
    
    return 0
}

# Build a single ISO variant
build_single_iso() {
    local variant="$1"
    local kernel_package=$(get_kernel_config "$variant")
    
    log_info "Building $variant ISO with $kernel_package kernel..."
    
    # Create variant-specific output directory
    local variant_output_dir="$OUTPUT_DIR/$variant"
    mkdir -p "$variant_output_dir"
    
    # Create temporary work directory
    local work_dir="$SCRIPT_DIR/archiso-$variant"
    
    # Clean previous work directory
    if [[ -d "$work_dir" ]]; then
        sudo rm -rf "$work_dir"
    fi
    
    # Update packages.x86_64 for this variant
    update_package_list_for_variant "$variant" "$kernel_package"
    
    # Ensure local repository is properly configured before ISO build
    log_info "Verifying local repository configuration before ISO build..."
    if ! update_archiso_pacman_config; then
        log_error "Failed to configure local repository for ISO build"
        return 1
    fi
    
    # Build the ISO
    local iso_build_log="$LOG_DIR/build-$variant.log"
    
    log_info "Running mkarchiso for $variant..."
    
    if [[ "$VERBOSE" == "true" ]]; then
        if ! sudo mkarchiso -v -w "$work_dir" -o "$variant_output_dir" "$ARCHISO_DIR" 2>&1 | tee "$iso_build_log"; then
            log_error "ISO build failed for $variant. Check log: $iso_build_log"
            return 1
        fi
    else
        if ! sudo mkarchiso -w "$work_dir" -o "$variant_output_dir" "$ARCHISO_DIR" >"$iso_build_log" 2>&1; then
            log_error "ISO build failed for $variant. Check log: $iso_build_log"
            return 1
        fi
    fi
    
    # Clean up work directory
    sudo rm -rf "$work_dir"
    
    log_success "Successfully built $variant ISO"
    
    # List built ISO files
    local iso_files=($(find "$variant_output_dir" -name "*.iso" -type f))
    if [[ ${#iso_files[@]} -gt 0 ]]; then
        log_info "Built ISO files:"
        for iso_file in "${iso_files[@]}"; do
            local iso_size=$(du -h "$iso_file" | cut -f1)
            log_info "  - $(basename "$iso_file") ($iso_size)"
        done
    fi
    
    return 0
}

# Update package list for specific variant
update_package_list_for_variant() {
    local variant="$1"
    local kernel_package="$2"
    local packages_file="$ARCHISO_DIR/packages.x86_64"
    
    # Create backup if it doesn't exist
    if [[ ! -f "$packages_file.backup" ]]; then
        cp "$packages_file" "$packages_file.backup"
    fi
    
    # Restore from backup and update for this variant
    cp "$packages_file.backup" "$packages_file"
    
    # Replace linux-t2 with the variant-specific kernel
    log_info "Replacing linux-t2 with $kernel_package in packages.x86_64"
    
    # Show before replacement
    log_info "Before replacement:"
    grep -n "linux-t2" "$packages_file" || log_info "  No linux-t2 entries found"
    
    sed -i "s/^linux-t2$/$kernel_package/" "$packages_file"
    
    # Show after replacement
    log_info "After replacement:"
    grep -n "linux-t2\|$kernel_package" "$packages_file" || log_info "  No matching entries found"
    
    log_info "Updated packages.x86_64 to use $kernel_package for $variant ISO"
    
    # Update other configuration files that reference the kernel
    update_kernel_references_for_variant "$variant" "$kernel_package"
}

# Update kernel references in configuration files for specific variant
update_kernel_references_for_variant() {
    local variant="$1"
    local kernel_package="$2"
    local grub_cfg="$ARCHISO_DIR/grub/grub.cfg"
    local mkinitcpio_preset="$ARCHISO_DIR/airootfs/etc/mkinitcpio.d/linux-t2.preset"
    
    log_info "Updating kernel references in configuration files for $kernel_package"
    
    # Backup grub.cfg if it doesn't exist
    if [[ ! -f "$grub_cfg.backup" ]]; then
        cp "$grub_cfg" "$grub_cfg.backup"
    fi
    
    # Backup mkinitcpio preset if it doesn't exist
    if [[ ! -f "$mkinitcpio_preset.backup" ]]; then
        cp "$mkinitcpio_preset" "$mkinitcpio_preset.backup"
    fi
    
    # Restore from backup and update for this variant
    cp "$grub_cfg.backup" "$grub_cfg"
    cp "$mkinitcpio_preset.backup" "$mkinitcpio_preset"
    
    # Update grub.cfg to use the correct kernel
    sed -i "s/vmlinuz-linux-t2/vmlinuz-$kernel_package/g" "$grub_cfg"
    sed -i "s/initramfs-linux-t2/initramfs-$kernel_package/g" "$grub_cfg"
    
    # Update mkinitcpio preset
    sed -i "s/vmlinuz-linux-t2/vmlinuz-$kernel_package/g" "$mkinitcpio_preset"
    sed -i "s/initramfs-linux-t2/initramfs-$kernel_package/g" "$mkinitcpio_preset"
    
    # Rename the preset file itself to match the kernel
    local new_preset="$ARCHISO_DIR/airootfs/etc/mkinitcpio.d/$kernel_package.preset"
    if [[ "$kernel_package" != "linux-t2" ]]; then
        mv "$mkinitcpio_preset" "$new_preset"
        log_info "Renamed mkinitcpio preset to $(basename "$new_preset")"
    fi
    
    log_info "Updated configuration files for $kernel_package"
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
    
    # Step 1: Setup kernel repository (only if not skipping kernel build)
    if [[ "$SKIP_KERNEL_BUILD" != "true" ]]; then
        if ! setup_kernel_repository; then
            log_error "Failed to setup kernel repository"
            exit 1
        fi
    fi
    
    # Step 2: Build T2 kernels for the specified variant
    if ! build_kernel_variants "$build_variant"; then
        log_error "Kernel building failed"
        exit 1
    fi
    
    # Step 2.1: Setup local repository with built packages
    if ! setup_local_repository; then
        log_error "Local repository setup failed"
        exit 1
    fi
    
    # Step 3: Build ISO variants
    if ! build_isos "$build_variant"; then
        log_error "ISO building failed"
        exit 1
    fi
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    log_success "Build completed successfully in ${total_time}s"
    log_info "Built ISO(s) are available in: $OUTPUT_DIR"
    
    exit 0
}

# Run main function with all arguments
main "$@"
