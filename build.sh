#!/usr/bin/env bash
set -e

# Define colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
clear_color='\033[0m'

# Memory-aware thread management
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_GB=$((MEM_KB / 1024 / 1024))
CORES=$(nproc --all)
THREADS=$((MEM_GB > 1 ? MEM_GB : 1))
[ "$THREADS" -gt "$CORES" ] && THREADS=$CORES

usage() {
    printf "${green}Usage: ${clear_color}$0 -m [laurel|gingko] [-c] [-h] [-b]\n"
    exit 1
}

SECONDS=0
topdir="$(pwd)"
out_dir="$topdir/out"
tc_dir="$topdir/toolchain"
tc_url="https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/10032024/neutron-clang-10032024.tar.zst"
ak3_dir="$topdir/AnyKernel3"

export KBUILD_BUILD_USER="Ikteach"
export KBUILD_BUILD_HOST="Linux"
make_options="O=$out_dir ARCH=arm64 CC=clang AS=llvm-as CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- LLVM=1 LLVM_IAS=1 DTC_EXT=$tc_dir/bin/dtc"
make_prefix=""

# Parse arguments
config_only=false
while getopts "m:chb" opt; do
    case $opt in
    m)
        model=$OPTARG
        if [ "$model" == "laurel" ]; then
            nh_config="nethunter_laurel_sprout_defconfig"; ak3_branch="laurel_sprout"
            zipname="laurel-sprout-nethunter-$(date '+%Y%m%d-%H%M').zip"
            tarball="laurel-sprout-modules-$(date '+%Y%m%d-%H%M').tar.gz"
            dtbo="arch/arm64/boot/dts/xiaomi/laurel_sprout-trinket-overlay.dtbo"
        elif [ "$model" == "gingko" ]; then
            nh_config="nethunter_gingko_defconfig"; ak3_branch="gingko"
            zipname="gingko-nethunter-$(date '+%Y%m%d-%H%M').zip"
            tarball="gingko-modules-$(date '+%Y%m%d-%H%M').tar.gz"
            dtbo="arch/arm64/boot/dts/xiaomi/ginkgo-trinket-overlay.dtbo"
        else
            printf "${red}Invalid model: $model${clear_color}\n"; usage
        fi
        ;;
    c) config_only=true ;;
    b) make_prefix="ionice -c 3 chrt --idle 0 nice -n19" ;;
    h) usage ;;
    esac
done

if [ -z "$model" ]; then usage; fi

# Environment setup
export PATH="$tc_dir/bin:$PATH"
[ -d "$tc_dir" ] || { mkdir -p "$tc_dir"; cd "$tc_dir"; curl -fsSL "$tc_url" | tar --zstd -xf -; cd "$topdir"; }

mkdir -p "$out_dir"

# --- Configuration Handling ---
if [ "$config_only" = true ]; then
    [ -f "$out_dir/.config" ] || cp "$topdir/arch/arm64/configs/$nh_config" "$out_dir/.config"
    printf "${yellow}Opening nconfig...${clear_color}\n"
    ${make_prefix} make ${make_options} nconfig
    printf "${yellow}Saving new configuration to $nh_config...${clear_color}\n"
    ${make_prefix} make ${make_options} savedefconfig
    cp "$out_dir/defconfig" "$topdir/arch/arm64/configs/$nh_config"
    printf "${green}Configuration updated and saved. Exiting.${clear_color}\n"
    exit 0
fi

# --- Build Execution ---
printf "${green}Starting compilation with $THREADS threads (RAM-aware)...${clear_color}\n"

# Configure if needed
[ -f "$out_dir/.config" ] || ${make_prefix} make ${make_options} $nh_config

# Build kernel and modules
${make_prefix} make ${make_options} -j$THREADS Image.gz modules

# Install modules
mod_out="$out_dir/modules_out"
rm -rf "$mod_out"
mkdir -p "$mod_out"
${make_prefix} make ${make_options} INSTALL_MOD_PATH="$mod_out" modules_install

# Kernel Packaging
[ -d "$ak3_dir" ] || git clone https://github.com/akabul0us/AnyKernel3 -b "$ak3_branch" "$ak3_dir"
cp "$out_dir/arch/arm64/boot/Image.gz" "$ak3_dir/"
gzip -dkc "$out_dir/arch/arm64/boot/Image.gz" > "$ak3_dir/Image"

cd "$ak3_dir"
[ -f "$topdir/$dtbo" ] && mkdtimg create dtbo.img "$topdir/$dtbo"
zip -r9 "../$zipname" * -x .git README.md
printf "${green}Kernel ZIP created: $zipname${clear_color}\n"

# Modules Packaging
cd "$topdir"
printf "${yellow}Packing modules...${clear_color}\n"
if [ -d "$mod_out/lib/modules" ]; then
    tar -czf "$tarball" -C "$mod_out/lib/modules" .
    printf "${green}Modules tarball created: $tarball${clear_color}\n"
else
    printf "${red}No modules found to pack.${clear_color}\n"
fi

printf "\nCompleted in $((SECONDS / 60))m $((SECONDS % 60))s!\n"
