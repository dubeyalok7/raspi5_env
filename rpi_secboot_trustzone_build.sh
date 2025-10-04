#!/usr/bin/env bash
set -euo pipefail

# ========= User Config =========
PI_MODEL="${PI_MODEL:-5}"              # "5" (experimental TZ) or "4"
ENABLE_TRUSTZONE="${ENABLE_TRUSTZONE:-true}"
ENABLE_SECURE_BOOT="${ENABLE_SECURE_BOOT:-true}"

WORKDIR="${WORKDIR:-$(pwd)/rpi5-build}"
BOOT="$WORKDIR/boot"
ROOTFS="$WORKDIR/rootfs"
STAGE="$WORKDIR/stage-root"
IMG="$WORKDIR/rpi.img"
GENIMAGE_CFG="$WORKDIR/genimage.cfg"
TOOLCHAIN_DIR="$WORKDIR/toolchains"
KEYS_DIR="$WORKDIR/keys"
SIGNED_DIR="$WORKDIR/signed"

mkdir -p "$WORKDIR" "$BOOT" "$ROOTFS" "$TOOLCHAIN_DIR" "$KEYS_DIR" "$SIGNED_DIR"
cd $WORKDIR
# ========= Helpers =========
have_cmd() { command -v "$1" >/dev/null 2>&1; }
require_tools() {
  for t in wget tar rsync make git sed genimage openssl; do
    have_cmd "$t" || { echo "❌ Missing tool: $t"; exit 1; }
  done
}
print_help() {
  cat <<'EOF'
Menu options:
  1) Download toolchains
  2) Clone sources
  3) Build U-Boot
  4) Build Kernel
  5) Build BusyBox
  6) Prepare rootfs
  7) Build TrustZone (OP-TEE OS 4.0.0 ta_arm64 + TF-A)
  8) Prepare boot files
  9) Write genimage.cfg
 10) Sign artifacts (Secure Boot)
 11) Generate SD image
  A|a) Build All
  H|h) Help
  C|c) Clean all
  0) Exit

Environment overrides:
  PI_MODEL=5|4
  ENABLE_TRUSTZONE=true|false
  ENABLE_SECURE_BOOT=true|false
  WORKDIR=/path/to/work

Notes:
- Toolchains are downloaded locally; system toolchains are ignored.
- OP-TEE OS pinned to 4.0.0; 64-bit TAs only (ta_arm64).
- optee_client is NOT cross-compiled here. Build it natively on the Pi after first boot:
    sudo apt-get update && sudo apt-get install uuid-dev make gcc
    make -C /root/optee_client && sudo make -C /root/optee_client install
EOF
}

# ========= Toolchains (download-only) =========
DL_TC64="$TOOLCHAIN_DIR/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"

TOOLCHAIN64_PREFIX="$DL_TC64"

download_toolchains() {
  mkdir -p "$TOOLCHAIN_DIR"
  pushd "$TOOLCHAIN_DIR" >/dev/null
  if [ ! -d gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu ]; then
    wget -c https://developer.arm.com/-/media/Files/downloads/gnu-a/10.3-2021.07/binrel/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu.tar.xz
    tar -xf gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu.tar.xz
  fi
  popd >/dev/null
}

ensure_toolchains() {
  download_toolchains
  if [ ! -x "${TOOLCHAIN64_PREFIX}gcc" ]; then
    echo "❌ AArch64 gcc not found at ${TOOLCHAIN64_PREFIX}gcc"; exit 1
  fi
  export ARCH=arm64
  export CROSS_COMPILE="$TOOLCHAIN64_PREFIX"
  echo "🔧 Using downloaded AArch64 toolchain: $TOOLCHAIN64_PREFIX"
}

# ========= Sources =========
clone_sources() {
  [ -d u-boot ]    || git clone --depth=1 https://github.com/u-boot/u-boot.git
  [ -d linux ]     || git clone --depth=1 https://github.com/raspberrypi/linux.git
  [ -d busybox ]   || git clone https://git.busybox.net/busybox
  [ -d firmware ]  || git clone --depth=1 https://github.com/raspberrypi/firmware.git

  if [ "$ENABLE_TRUSTZONE" = "true" ] ; then
    [ -d trusted-firmware-a ] || git clone --depth=1 https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git
    if [ ! -d optee_os ]; then
      git clone https://github.com/OP-TEE/optee_os.git
      pushd optee_os >/dev/null
      git fetch --tags
      git checkout 4.0.0
      git submodule update --init --recursive
      popd >/dev/null
    fi
    [ -d optee_client ] || git clone --depth=1 https://github.com/OP-TEE/optee_client.git
  fi
}

# ========= Build: U-Boot / Kernel / BusyBox / Rootfs =========
build_uboot() {
  pushd u-boot >/dev/null
  make rpi_arm64_defconfig
  make -j"$(nproc)"
  popd >/dev/null
}

build_kernel() {
  pushd linux >/dev/null
  if [ "$PI_MODEL" = "4" ]; then
    make bcm2711_defconfig
  else
    make bcm2712_defconfig
  fi
  make -j"$(nproc)" Image dtbs modules
  popd >/dev/null
}

build_busybox() {
  pushd busybox >/dev/null
  [ -f .config ] || make defconfig
  make -j"$(nproc)"
  make install
  popd >/dev/null
}

prepare_rootfs() {
  rsync -a --delete busybox/_install/ "$ROOTFS/"
  mkdir -p "$ROOTFS"/{proc,sys,dev,etc,tmp,var,usr,lib}
  make -C linux ARCH=arm64 CROSS_COMPILE="${TOOLCHAIN64_PREFIX}" \
       modules_install INSTALL_MOD_PATH="$ROOTFS"
  # Reminder for optee_client native build on Pi
  mkdir -p "$ROOTFS/usr/share/doc"
  cat > "$ROOTFS/usr/share/doc/OPTEE_CLIENT_BUILD_ON_PI.txt" <<'EON'
This image does not include optee_client (tee-supplicant, libteec).
Build it natively on your Raspberry Pi:
  sudo apt-get update && sudo apt-get install uuid-dev make gcc
  cd /root/optee_client && make && sudo make install
EON
}

# ========= TrustZone: OP-TEE OS 4.0.0 (ta_arm64 only) + TF-A =========
build_trustzone() {
  if [ "$ENABLE_TRUSTZONE" != "true" ]; then
    echo "ℹ️ TrustZone disabled. Skipping OP-TEE/TF-A."
    return 0
  fi

====================================================  TODO =================================================
  echo "🔐 Building OP-TEE OS 4.0.0 (ta_arm64 only)... { TODO }"
  #pushd optee_os >/dev/null
  #rm -rf out || true
  #make clean
  #env -i PATH="$PATH" \
  #  make -j"$(nproc)" \
  #    PLATFORM=rpi3 \
  #    CFG_ARM64_core=y \
  #    ta-targets=ta_arm64 \
  #    CROSS_COMPILE="${TOOLCHAIN64_PREFIX}"
  #popd >/dev/null
============================================================================================================

  local tee_bin="optee_os/out/arm-plat-rpi3/core/tee.bin"
  if [ ! -f "$tee_bin" ]; then
    echo "❌ OP-TEE tee.bin not found at $tee_bin"
    return 1
  fi

  echo "🔐 Building TF-A for TrustZone handoff..."
  pushd trusted-firmware-a >/dev/null
  if [ "$PI_MODEL" = "4" ]; then
    make -j"$(nproc)" \
      PLAT=rpi4 SPD=opteed \
      BL32="$(pwd)/../$tee_bin" \
      DEBUG=0
    cp build/rpi4/release/bl31.bin "$BOOT/armstub8.bin" || true
  else
    if make -n PLAT=bcm2712 >/dev/null 2>&1; then
      make -j"$(nproc)" \
        PLAT=bcm2712 SPD=opteed \
        BL32="$(pwd)/../$tee_bin" \
        DEBUG=0 || true
      cp build/bcm2712/release/bl31.bin "$BOOT/armstub8.bin" || true
    else
      echo "⚠️ TF-A bcm2712 not supported on this branch; skipping armstub8.bin."
    fi
  fi
  popd >/dev/null

  echo "✅ OP-TEE OS 4.0.0 built (ta_arm64 only); TF-A handoff prepared."
}

# ========= Boot prep =========
prepare_boot() {
  cp firmware/boot/*.elf "$BOOT" || true
  cp firmware/boot/*.dat "$BOOT" || true
  mkdir -p "$BOOT/overlays"
  cp -r firmware/boot/overlays/* "$BOOT/overlays" || true

  cp linux/arch/arm64/boot/Image "$BOOT"
  cp linux/arch/arm64/boot/dts/broadcom/*.dtb "$BOOT"
  cp u-boot/u-boot.bin "$BOOT"

  cat > "$BOOT/config.txt" <<EOF
arm_64bit=1
enable_uart=1
kernel=u-boot.bin
# Enable TF-A handoff if BL31 is present:
# armstub8=armstub8.bin
EOF

  echo "console=serial0,115200 rw" > "$BOOT/cmdline.txt"
  if [ -f "$BOOT/armstub8.bin" ]; then
    sed -i 's/^# armstub8=armstub8.bin/armstub8=armstub8.bin/' "$BOOT/config.txt"
  fi
}

# ========= genimage config =========
write_genimage_cfg() {
  cat > "$GENIMAGE_CFG" <<'EOF'
image boot.vfat {
  vfat { label = "BOOT" }
  size = 256M
  mountpoint = "/boot"
}
image rootfs.ext4 {
  ext4 { label = "rootfs" }
  size = 2048M
  mountpoint = "/"
}
image rpi.img {
  hdimage { partition-table-type = "dos" }
  partition boot {
    partition-type = 0x0C
    bootable = "true"
    image = "boot.vfat"
  }
  partition rootfs {
    partition-type = 0x83
    image = "rootfs.ext4"
  }
}
EOF
}

generate_image() {
  rm -rf "$STAGE"
  mkdir -p "$STAGE/boot"
  cp -r "$BOOT/"* "$STAGE/boot/"
  rsync -a --exclude=boot/ "$ROOTFS/" "$STAGE/"

  if [ ! -s "$STAGE/boot/u-boot.bin" ]; then
    echo "❌ ERROR: Boot files missing in $STAGE/boot"
    return 1
  fi
  if [ ! -x "$STAGE/bin/sh" ]; then
    echo "❌ ERROR: Rootfs missing in $STAGE"
    return 1
  fi

  rm -f "$IMG"
  genimage \
    --rootpath "$STAGE" \
    --tmppath "$WORKDIR/tmp" \
    --inputpath "$WORKDIR" \
    --outputpath "$WORKDIR" \
    --config "$GENIMAGE_CFG" \
    --loglevel 2

  echo "✅ Image ready: $IMG"
  echo "Flash with Raspberry Pi Imager (Use custom) or:"
  echo "    sudo dd if='$IMG' of=/dev/sdX bs=4M status=progress conv=fsync"
}

# ========= Secure Boot (keys + signing) =========
generate_keys() {
  mkdir -p "$KEYS_DIR"
  if [ ! -f "$KEYS_DIR/private.pem" ]; then
    echo "🔑 Generating RSA-2048 keypair..."
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEYS_DIR/private.pem"
    openssl rsa -in "$KEYS_DIR/private.pem" -pubout -out "$KEYS_DIR/public.pem"
    echo "✅ Keys generated in $KEYS_DIR"
  else
    echo "ℹ️ Keys already exist in $KEYS_DIR"
  fi
}

sign_artifacts() {
  if [ "$ENABLE_SECURE_BOOT" != "true" ]; then
    echo "ℹ️ Secure Boot disabled. Skipping signing."
    return 0
  fi

  generate_keys
  mkdir -p "$SIGNED_DIR"

  if [ -f firmware/boot/start4.elf ]; then
    echo "🔏 Signing start4.elf..."
    openssl dgst -sha256 -sign "$KEYS_DIR/private.pem" \
      -out "$SIGNED_DIR/start4.elf.sig" firmware/boot/start4.elf
  fi

  if [ -f "$BOOT/u-boot.bin" ]; then
    echo "🔏 Signing U-Boot (u-boot.bin)..."
    openssl dgst -sha256 -sign "$KEYS_DIR/private.pem" \
      -out "$SIGNED_DIR/u-boot.bin.sig" "$BOOT/u-boot.bin"
  fi

  if [ -f "$BOOT/Image" ]; then
    echo "🔏 Signing kernel (Image)..."
    openssl dgst -sha256 -sign "$KEYS_DIR/private.pem" \
      -out "$SIGNED_DIR/Image.sig" "$BOOT/Image"
  fi

  echo "✅ Artifacts signed. Signatures stored in $SIGNED_DIR"
  echo "⚠️ Pi 5 Secure Boot requires OTP programming and signed EEPROM/firmware flow."
}

# ========= Clean =========
clean_all() {
  rm -rf "$BOOT" "$ROOTFS" "$STAGE" "$IMG" "$WORKDIR/tmp"
  echo "🧹 Cleaned build artifacts (sources and toolchains retained)"
}

# ========= Complete pipeline =========
build_all() {
  require_tools
  ensure_toolchains
  clone_sources
  build_uboot
  build_kernel
  build_busybox
  prepare_rootfs
  build_trustzone
  prepare_boot
  write_genimage_cfg
  sign_artifacts
  generate_image
}

# ========= Menu =========
while true; do
  echo "=============================================="
  echo " Raspberry Pi Build (Pi${PI_MODEL}, TZ=${ENABLE_TRUSTZONE}, SecureBoot=${ENABLE_SECURE_BOOT})"
  echo "=============================================="
  echo "Workdir: $WORKDIR"
  echo "Toolchains dir: $TOOLCHAIN_DIR"
  echo "Keys dir: $KEYS_DIR"
  echo "1) Download toolchains"
  echo "2) Clone sources"
  echo "3) Build U-Boot"
  echo "4) Build Kernel"
  echo "5) Build BusyBox"
  echo "6) Prepare rootfs"
  echo "7) Build TrustZone (OP-TEE OS 4.0.0 ta_arm64 + TF-A)"
  echo "8) Prepare boot files"
  echo "9) Write genimage.cfg"
  echo "10) Sign artifacts (Secure Boot)"
  echo "11) Generate SD image"
  echo "A|a) Build All (complete pipeline)"
  echo "H|h) Help"
  echo "C|c) Clean all"
  echo "0) Exit"
  read -rp "Select option: " opt

  case "$opt" in
    1) download_toolchains ;;
    2) clone_sources ;;
    3) build_uboot ;;
    4) build_kernel ;;
    5) build_busybox ;;
    6) prepare_rootfs ;;
    7) build_trustzone ;;
    8) prepare_boot ;;
    9) write_genimage_cfg ;;
    10) sign_artifacts ;;
    11) generate_image ;;
    A|a) build_all ;;
    H|h) print_help ;;
    C|c) clean_all ;;
    0) exit 0 ;;
    *) echo "Invalid option" ;;
  esac
done
