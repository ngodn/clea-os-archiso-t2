#!/bin/bash
# Enhanced T2 Arch ISO Build System
# 
# Original T2 ISO by Noa Himesaka
# Enhanced build system by ngodn (eins0fx) <https://github.com/ngodn>

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHISO_DIR="$SCRIPT_DIR/archiso"
OUTPUT_DIR="$SCRIPT_DIR/out"
LOG_DIR="$SCRIPT_DIR/build-logs"
BUILD_VARIANTS=("default" "lts" "xanmod" "xanmod-lts" "liquorix")
DEFAULT_KERNEL="linux-t2"
CLEAN_BUILD=${CLEAN_BUILD:-false}
VERBOSE=${VERBOSE:-false}

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
    mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
    log_info "Created build directories"
}

# Check system requirements
check_requirements() {
    local required_commands=("mkarchiso" "sudo" "git" "curl")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        echo "Please install: sudo pacman -S archiso git curl"
        return 1
    fi
    
    # Check if running as root or with sudo access
    if [[ $EUID -eq 0 ]]; then
        log_warning "Running as root - this is not recommended"
    elif ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo access for mkarchiso"
    fi
    
    log_success "System requirements check passed"
}

# Get kernel variant configuration
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

# Create variant-specific archiso profile
create_variant_profile() {
    local variant="$1"
    local kernel=$(get_kernel_config "$variant")
    local profile_dir="$SCRIPT_DIR/archiso-$variant"
    
    log_info "Creating profile for variant: $variant (kernel: $kernel)"
    
    # Copy base archiso directory
    if [[ -d "$profile_dir" ]]; then
        rm -rf "$profile_dir"
    fi
    cp -r "$ARCHISO_DIR" "$profile_dir"
    
    # Update profiledef.sh for variant
    sed -i "s/iso_name=\"archlinux-t2\"/iso_name=\"archlinux-t2-$variant\"/" "$profile_dir/profiledef.sh"
    sed -i "s/iso_label=\"ARCH_.*_t2\"/iso_label=\"ARCH_$(date +%Y%m)_t2_$variant\"/" "$profile_dir/profiledef.sh"
    sed -i "s/iso_application=\".*\"/iso_application=\"Arch Linux Live\/Rescue CD for T2 Macs ($variant kernel)\"/" "$profile_dir/profiledef.sh"
    sed -i "s/iso_version=\".*\"/iso_version=\"$(date +%Y.%m.%d)-t2-$variant\"/" "$profile_dir/profiledef.sh"
    
    # Update packages.x86_64 to use specific kernel as primary
    local temp_packages="$profile_dir/packages.x86_64.tmp"
    {
        # Add the primary kernel first
        echo "$kernel"
        
        # Add other packages, excluding other kernel variants from being primary
        grep -v "^linux-t2" "$profile_dir/packages.x86_64" || true
        
        # Add all kernel variants for flexibility (users can choose during installation)
        echo "linux-t2"
        echo "linux-t2-lts" 
        echo "linux-t2-xanmod"
        echo "linux-t2-xanmod-lts"
        echo "linux-t2-liquorix"
    } > "$temp_packages"
    
    mv "$temp_packages" "$profile_dir/packages.x86_64"
    
    # Update mkinitcpio preset for the specific kernel
    if [[ -f "$profile_dir/airootfs/etc/mkinitcpio.d/linux-t2.preset" ]]; then
        cp "$profile_dir/airootfs/etc/mkinitcpio.d/linux-t2.preset" \
           "$profile_dir/airootfs/etc/mkinitcpio.d/$kernel.preset"
        
        # Update preset content
        sed -i "s/linux-t2/$kernel/g" "$profile_dir/airootfs/etc/mkinitcpio.d/$kernel.preset"
    fi
    
    log_success "Created profile for $variant variant"
}

# Build single ISO variant
build_iso_variant() {
    local variant="$1"
    local profile_dir="$SCRIPT_DIR/archiso-$variant"
    local build_log="$LOG_DIR/build-iso-$variant.log"
    local variant_output="$OUTPUT_DIR/$variant"
    
    log_info "Building ISO for variant: $variant"
    
    # Create variant profile
    create_variant_profile "$variant"
    
    # Create variant output directory
    mkdir -p "$variant_output"
    
    # Clean previous build if requested
    if [[ "$CLEAN_BUILD" == "true" ]]; then
        log_info "Cleaning previous build for $variant"
        rm -rf "$variant_output"/* "$profile_dir/work" "$profile_dir/out"
    fi
    
    # Start build process
    local start_time=$(date +%s)
    
    cd "$profile_dir"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Building $variant ISO (verbose mode)"
        if ! sudo mkarchiso -v -w work -o "$variant_output" . 2>&1 | tee "$build_log"; then
            log_error "ISO build failed for $variant. Check log: $build_log"
            return 1
        fi
    else
        log_info "Building $variant ISO (quiet mode, logging to $build_log)"
        if ! sudo mkarchiso -v -w work -o "$variant_output" . >"$build_log" 2>&1; then
            log_error "ISO build failed for $variant. Check log: $build_log"
            return 1
        fi
    fi
    
    local end_time=$(date +%s)
    local build_time=$((end_time - start_time))
    
    log_success "Successfully built $variant ISO in ${build_time}s"
    
    # List generated ISOs
    local isos=($(find "$variant_output" -name "*.iso" 2>/dev/null || true))
    if [[ ${#isos[@]} -gt 0 ]]; then
        log_info "Generated ISO for $variant:"
        for iso in "${isos[@]}"; do
            echo "  - $(basename "$iso") ($(du -h "$iso" | cut -f1))"
        done
    fi
    
    # Cleanup variant profile
    rm -rf "$profile_dir"
    
    return 0
}

# Build all variants
build_all_variants() {
    local failed_builds=()
    local successful_builds=()
    
    log_info "Building ISO variants: ${BUILD_VARIANTS[*]}"
    
    for variant in "${BUILD_VARIANTS[@]}"; do
        if build_iso_variant "$variant"; then
            successful_builds+=("$variant")
        else
            failed_builds+=("$variant")
        fi
    done
    
    # Report results
    echo
    log_info "Build Summary:"
    
    if [[ ${#successful_builds[@]} -gt 0 ]]; then
        log_success "Successfully built: ${successful_builds[*]}"
    fi
    
    if [[ ${#failed_builds[@]} -gt 0 ]]; then
        log_error "Failed builds: ${failed_builds[*]}"
        return 1
    fi
    
    log_success "All ISO builds completed successfully!"
    return 0
}

# Generate build report
generate_report() {
    local report_file="$LOG_DIR/iso-build-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "T2 Arch ISO Build Report"
        echo "======================="
        echo "Build Date: $(date)"
        echo "Script Directory: $SCRIPT_DIR"
        echo "Output Directory: $OUTPUT_DIR"
        echo "Clean Build: $CLEAN_BUILD"
        echo
        
        echo "System Information:"
        echo "- OS: $(uname -a)"
        echo "- CPU: $(nproc) cores"
        echo "- Memory: $(free -h | grep Mem | awk '{print $2}')"
        echo "- Disk Space: $(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $4}')"
        echo
        
        echo "Built ISO Variants:"
        for variant in "${BUILD_VARIANTS[@]}"; do
            local variant_output="$OUTPUT_DIR/$variant"
            if [[ -d "$variant_output" ]]; then
                echo "- $variant:"
                local isos=($(find "$variant_output" -name "*.iso" 2>/dev/null || true))
                if [[ ${#isos[@]} -gt 0 ]]; then
                    for iso in "${isos[@]}"; do
                        echo "  * $(basename "$iso") ($(du -h "$iso" | cut -f1))"
                    done
                else
                    echo "  * No ISOs found"
                fi
            fi
        done
        
        echo
        echo "Build Logs:"
        for log_file in "$LOG_DIR"/build-iso-*.log; do
            if [[ -f "$log_file" ]]; then
                echo "- $(basename "$log_file"): $(wc -l < "$log_file") lines"
            fi
        done
        
    } > "$report_file"
    
    log_info "Build report generated: $report_file"
}

# Show usage
show_usage() {
    echo "Enhanced T2 Arch ISO Build System"
    echo "================================"
    echo
    echo "Usage: $0 [OPTIONS] [VARIANT]"
    echo
    echo "Options:"
    echo "  -c, --clean     Clean previous builds"
    echo "  -v, --verbose   Verbose output"
    echo "  -h, --help      Show this help"
    echo
    echo "Variants:"
    echo "  default         Mainline T2 kernel (linux-t2)"
    echo "  lts             LTS T2 kernel (linux-t2-lts)"
    echo "  xanmod          XanMod T2 kernel (linux-t2-xanmod)"
    echo "  xanmod-lts      XanMod LTS T2 kernel (linux-t2-xanmod-lts)"
    echo "  liquorix        Liquorix T2 kernel (linux-t2-liquorix)"
    echo "  all             Build all variants (default)"
    echo
    echo "Examples:"
    echo "  $0                    # Build all variants"
    echo "  $0 xanmod            # Build only XanMod variant"
    echo "  $0 --clean --verbose  # Clean build with verbose output"
    echo "  $0 -c lts            # Clean build of LTS variant"
}

# Main function
main() {
    local build_variant="all"
    
    echo "Enhanced T2 Arch ISO Build System"
    echo "================================="
    
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
    echo
    
    local start_time=$(date +%s)
    
    # Build ISOs
    if [[ "$build_variant" == "all" ]]; then
        if build_all_variants; then
            local end_time=$(date +%s)
            local total_time=$((end_time - start_time))
            
            log_success "All ISO builds completed in ${total_time}s"
            generate_report
            
            echo
            log_info "Built ISOs are available in: $OUTPUT_DIR/"
            log_info "Build logs are available in: $LOG_DIR/"
            
            exit 0
        else
            log_error "Some ISO builds failed. Check logs in $LOG_DIR/"
            exit 1
        fi
    else
        # Build single variant
        if build_iso_variant "$build_variant"; then
            local end_time=$(date +%s)
            local total_time=$((end_time - start_time))
            
            log_success "ISO build completed in ${total_time}s"
            generate_report
            
            echo
            log_info "Built ISO is available in: $OUTPUT_DIR/$build_variant/"
            log_info "Build log is available in: $LOG_DIR/"
            
            exit 0
        else
            log_error "ISO build failed. Check logs in $LOG_DIR/"
            exit 1
        fi
    fi
}

# Run main function with all arguments
main "$@"
