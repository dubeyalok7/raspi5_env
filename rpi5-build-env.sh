#!/usr/bin/env bash
set -euo pipefail

# ====================================
# rpi5-build-secure-serial.sh
# Builds kernel/rootfs, optional TrustZone (TF-A + OP-TEE), signs artifacts,
# produces rpi.img and provides serial QEMU runners. This version:
# - prefers u-boot.elf when present
# - attempts qemu_arm64 U-Boot build when needed
# - detects whether 'host' CPU is supported and falls back to cortex-a72
# - offers a debug run that starts QEMU paused for gdb and writes a detailed qemu log
# - preserves the interactive menu (options unchanged)
# ====================================

PI_MODEL="${PI_MODEL:-5}"
ENABLE_TRUSTZONE="${ENABLE_TRUSTZONE:-true}"
ENABLE_SECURE_BOOT="${ENABLE_SECURE_BOOT:-true}"
AUTO_BUILD_QEMU_UBOOT="${AUTO_BUILD_QEMU_UBOOT:-true}"

WORKDIR="${WORKDIR:-$(pwd)/rpi5-build}"
BOOT="$WORKDIR/boot"
ROOTFS="$WORKDIR/rootfs"
STAGE="$WORKDIR/stage-root"
IMG="$WORKDIR/rpi.img"
GENIMAGE_CFG="$WORKDIR/genimage.cfg"
TOOLCHAIN_DIR="$WORKDIR/toolchains"
KEYS_DIR="$WORKDIR/keys"
SIGNED_DIR="$WORKDIR/signed"
KERNEL_OUT="$WORKDIR/kernel.img"
INITRD_TAR="$WORKDIR/rootfs.tar"
RUN_QEMU_SERIAL="$WORKDIR/run-qemu-serial.sh"
RUN_QEMU_UBOOT="$WORKDIR/run-qemu-uboot.sh"
RUN_QEMU_UBOOT_DEBUG="$WORKDIR/run-qemu-uboot-debug.sh"
VIRT_ROOT_IMG="$WORKDIR/virt-root.img"
QEMU_LOG="$WORKDIR/qemu-firmware.log"
GDB_PORT="${GDB_PORT:-1234}"

mkdir -p "$WORKDIR" "$BOOT" "$ROOTFS" "$TOOLCHAIN_DIR" "$KEYS_DIR" "$SIGNED_DIR"

have_cmd(){ command -v "$1" >/dev/null 2>&1; }
info(){ printf "\n== %s\n" "$1"; }

require_tools(){
  for t in wget tar rsync make git sed genimage openssl qemu-system-aarch64 losetup kpartx dd mkfs.ext4 file readelf objdump; do
    have_cmd "$t" || { echo "Missing tool: $t"; exit 1; }
  done
}

# CPU fallback: prefer host when supported, otherwise use cortex-a72
detect_qemu_cpu(){
  if qemu-system-aarch64 -cpu host -nographic -S >/dev/null 2>&1; then
    QEMU_CPU_FOR_FIRMWARE="host"
  else
    QEMU_CPU_FOR_FIRMWARE="cortex-a72"
  fi
}
detect_qemu_cpu

print_help(){
  cat <<'EOF'
Menu:
 1) Download toolchains
 2) Clone sources
 3) Build U-Boot (Pi target)
 3b) Build U-Boot for QEMU/virt (qemu_arm64)
 4) Build Kernel
 5) Build BusyBox
 6) Prepare rootfs (BusyBox init + getty on tty1)
 7) Build TrustZone (OP-TEE + TF-A)
 8) Prepare boot partition (config + cmdline)
 9) Produce QEMU artifacts + serial runners
10) Run QEMU serial runner (kernel direct or U-Boot)
11) Generate keys for signing
12) Sign artifacts (BL31/BL32/BL33/kernel/u-boot)
13) Create OTP provisioning package
14) Write genimage.cfg
15) Generate SD image (rpi.img)
16) Generate SD image with TrustZone included
17) Create virt-root.img (for U-Boot -> virtio test)
18) Run U-Boot firmware under QEMU paused for gdb (debug run)
 A) Build All
 C) Clean
 H) Help
 0) Exit
EOF
}

# -----------------------
# Toolchain
# -----------------------
DL_TC64="$TOOLCHAIN_DIR/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
TOOLCHAIN64_PREFIX="$DL_TC64"

download_toolchains(){
  info "Downloading AArch64 toolchain (if missing)"
  mkdir -p "$TOOLCHAIN_DIR"
  pushd "$TOOLCHAIN_DIR" >/dev/null
  if [ ! -d gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu ]; then
    wget -c https://developer.arm.com/-/media/Files/downloads/gnu-a/10.3-2021.07/binrel/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu.tar.xz
    tar -xf gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu.tar.xz
  fi
  popd >/dev/null
}

ensure_toolchains(){
  download_toolchains
  if [ ! -x "${TOOLCHAIN64_PREFIX}gcc" ]; then
    echo "AArch64 gcc missing at ${TOOLCHAIN64_PREFIX}gcc"; exit 1
  fi
  export ARCH=arm64
  export CROSS_COMPILE="${TOOLCHAIN64_PREFIX}"
  info "Using CROSS_COMPILE=$CROSS_COMPILE"
}

# -----------------------
# Sources
# -----------------------
clone_sources(){
  info "Cloning sources"
  [ -d u-boot ]    || git clone --depth=1 https://github.com/u-boot/u-boot.git
  [ -d linux ]     || git clone --depth=1 https://github.com/raspberrypi/linux.git
  [ -d busybox ]   || git clone https://git.busybox.net/busybox
  [ -d firmware ]  || git clone --depth=1 https://github.com/raspberrypi/firmware.git

  if [ "$ENABLE_TRUSTZONE" = "true" ]; then
    [ -d trusted-firmware-a ] || git clone --depth=1 https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git
    if [ ! -d optee_os ]; then
      git clone https://github.com/OP-TEE/optee_os.git
      pushd optee_os >/dev/null
      git fetch --tags || true
      git checkout 4.0.0 || true
      git submodule update --init --recursive || true
      popd >/dev/null
    fi
    [ -d optee_client ] || git clone --depth=1 https://github.com/OP-TEE/optee_client.git
  fi
}

# -----------------------
# Build steps
# -----------------------
build_uboot(){
  info "Building U-Boot (Pi defconfig)"
  pushd u-boot >/dev/null
  make rpi_arm64_defconfig
  make -j"$(nproc)"
  popd >/dev/null
  info "U-Boot built: u-boot/u-boot.bin (Pi target)"
}

build_uboot_qemu(){
  info "Building U-Boot for QEMU/virt (qemu_arm64_defconfig or qemu-like)"
  pushd u-boot >/dev/null
  make distclean || true
  if [ -f configs/qemu_arm64_defconfig ]; then
    make qemu_arm64_defconfig || true
  else
    if ls configs/*qemu* >/dev/null 2>&1; then
      cfg=$(ls configs/*qemu* | head -n1)
      make "$(basename "$cfg")" || true
    else
      echo "No qemu defconfig found; list configs in u-boot/configs for a suitable defconfig."
      ls configs | sed -n '1,200p'
    fi
  fi
  make -j"$(nproc)" || true
  popd >/dev/null
  info "Attempted qemu U-Boot build"
}

build_kernel(){
  info "Building kernel (Image dtbs modules)"
  pushd linux >/dev/null
  if [ "$PI_MODEL" = "4" ]; then
    make bcm2711_defconfig
  else
    if grep -q "rpi5" Makefile >/dev/null 2>&1; then
      make rpi5_defconfig || true
    else
      make bcm2711_defconfig || true
    fi
  fi
  make -j"$(nproc)" Image dtbs modules
  popd >/dev/null
  info "Kernel build complete"
}

build_busybox(){
  info "Building BusyBox and installing to $ROOTFS"
  pushd busybox >/dev/null
  [ -f .config ] || make defconfig
  make -j"$(nproc)"
  make CONFIG_PREFIX="$ROOTFS" install
  popd >/dev/null
  info "BusyBox installed into rootfs"
}

prepare_rootfs(){
  info "Preparing rootfs with BusyBox init and getty on tty1"
  mkdir -p "$ROOTFS"/{proc,sys,dev,etc,tmp,var,usr,lib,run,root}
  if [ -d linux ]; then
    make -C linux ARCH=arm64 CROSS_COMPILE="${TOOLCHAIN64_PREFIX}" modules_install INSTALL_MOD_PATH="$ROOTFS" || true
  fi
  mkdir -p "$ROOTFS/sbin"
  ln -sf /bin/busybox "$ROOTFS/sbin/init"
  mkdir -p "$ROOTFS/etc"
  cat > "$ROOTFS/etc/inittab" <<'EOF'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::respawn:/sbin/getty -n -l /bin/sh 115200 tty1
EOF
  cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
  cat > "$ROOTFS/etc/shadow" <<'EOF'
root::0:99999:7:::
EOF
  chmod 0644 "$ROOTFS/etc/passwd" || true
  chmod 0644 "$ROOTFS/etc/shadow" || true
  if [ ! -e "$ROOTFS/dev/console" ]; then
    sudo sh -c "mkdir -p '$ROOTFS/dev'; mknod -m 622 '$ROOTFS/dev/console' c 5 1 || true; mknod -m 666 '$ROOTFS/dev/null' c 1 3 || true"
  fi
  info "Rootfs prepared at $ROOTFS"
}

# -----------------------
# TrustZone (OP-TEE + TF-A)
# -----------------------
build_trustzone(){
  if [ "$ENABLE_TRUSTZONE" != "true" ]; then
    info "TrustZone disabled"
    return 0
  fi
  info "Attempting OP-TEE OS + TF-A build (best-effort)"
  if [ -d optee_os ]; then
    pushd optee_os >/dev/null
    make clean || true
    env -i PATH="$PATH" make -j"$(nproc)" PLATFORM=rpi3 CFG_ARM64_core=y ta-targets=ta_arm64 CROSS_COMPILE="${TOOLCHAIN64_PREFIX}" || true
    popd >/dev/null
  fi
  if [ -d trusted-firmware-a ]; then
    pushd trusted-firmware-a >/dev/null
    if make -n PLAT=rpi5 >/dev/null 2>&1; then
      make -j"$(nproc)" PLAT=rpi5 SPD=opteed DEBUG=0 || true
      cp build/rpi5/release/bl31.bin "$BOOT/armstub8.bin" 2>/dev/null || true
    elif make -n PLAT=rpi4 >/dev/null 2>&1; then
      make -j"$(nproc)" PLAT=rpi4 SPD=opteed DEBUG=0 || true
      cp build/rpi4/release/bl31.bin "$BOOT/armstub8.bin" 2>/dev/null || true
    else
      echo "TF-A rpi5/rpi4 target not found; update TF-A"
    fi
    popd >/dev/null
  fi
  info "TrustZone build attempted"
}

# -----------------------
# Boot partition
# -----------------------
prepare_boot(){
  info "Preparing boot partition files"
  mkdir -p "$BOOT/overlays"
  cp -r firmware/boot/* "$BOOT/" 2>/dev/null || true
  cp linux/arch/arm64/boot/Image "$BOOT/" 2>/dev/null || true
  cp linux/arch/arm64/boot/dts/broadcom/*.dtb "$BOOT/" 2>/dev/null || true
  cp u-boot/u-boot.bin "$BOOT/" 2>/dev/null || true
  cat > "$BOOT/config.txt" <<'EOF'
arm_64bit=1
hdmi_force_hotplug=1
hdmi_drive=2
disable_splash=1
hdmi_safe=0
#kernel=u-boot.bin
EOF
  cat > "$BOOT/cmdline.txt" <<'EOF'
console=tty1 root=/dev/mmcblk0p2 rw rootwait loglevel=7
EOF
  if [ -f "$BOOT/armstub8.bin" ]; then
    sed -i 's/^#kernel=u-boot.bin/kernel=u-boot.bin/' "$BOOT/config.txt" || true
  fi
  info "Boot files prepared in $BOOT"
}

# -----------------------
# Signing helpers
# -----------------------
generate_keys(){
  info "Generating RSA keypair (2048)"
  mkdir -p "$KEYS_DIR"
  if [ ! -f "$KEYS_DIR/private.pem" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEYS_DIR/private.pem"
    openssl rsa -in "$KEYS_DIR/private.pem" -pubout -out "$KEYS_DIR/public.pem"
    echo "Generated RSA-2048 keys"
  else
    echo "Keys already exist in $KEYS_DIR"
  fi
  openssl pkey -pubin -in "$KEYS_DIR/public.pem" -outform der | sha256sum | awk '{print $1}' > "$KEYS_DIR/public_sha256.txt"
  info "Public key SHA256: $(cat "$KEYS_DIR/public_sha256.txt")"
}

sign_artifact(){
  local in="$1" outsig="$2"
  if [ ! -f "$in" ]; then echo "Missing input to sign: $in"; return 1; fi
  openssl dgst -sha256 -sign "$KEYS_DIR/private.pem" -out "$outsig" "$in"
  info "Signed $in -> $outsig"
}

sign_artifacts(){
  if [ "$ENABLE_SECURE_BOOT" != "true" ]; then
    info "Secure boot disabled; skipping signing"
    return 0
  fi
  generate_keys
  mkdir -p "$SIGNED_DIR"
  if [ -f "$BOOT/armstub8.bin" ]; then
    sign_artifact "$BOOT/armstub8.bin" "$SIGNED_DIR/bl31.sig"
  fi
  if [ -f "$BOOT/u-boot.bin" ]; then
    sign_artifact "$BOOT/u-boot.bin" "$SIGNED_DIR/u-boot.bin.sig"
  fi
  if [ -f "$BOOT/Image" ]; then
    sign_artifact "$BOOT/Image" "$SIGNED_DIR/Image.sig"
  fi
  if [ -f firmware/boot/start4.elf ]; then
    sign_artifact "firmware/boot/start4.elf" "$SIGNED_DIR/start4.elf.sig"
  fi
  cp -a "$SIGNED_DIR"/* "$BOOT/" 2>/dev/null || true
  info "Signed artifacts placed in $SIGNED_DIR"
}

create_otp_package(){
  info "Creating OTP provisioning package"
  mkdir -p "$KEYS_DIR/otp_package"
  cp "$KEYS_DIR/public.pem" "$KEYS_DIR/otp_package/" 2>/dev/null || true
  cp "$KEYS_DIR/public_sha256.txt" "$KEYS_DIR/otp_package/" 2>/dev/null || true
  cat > "$KEYS_DIR/otp_package/manifest.txt" <<EOF
# OTP provisioning package for development
# public_key_sha256: $(cat "$KEYS_DIR/public_sha256.txt")
# files:
#   public.pem
#   public_sha256.txt
EOF
  info "OTP package at $KEYS_DIR/otp_package"
}

# -----------------------
# QEMU artifacts and runners
# -----------------------
produce_qemu_artifacts(){
  info "Producing kernel.img + rootfs.tar for QEMU (serial testing)"
  if [ ! -f linux/arch/arm64/boot/Image ]; then
    echo "Kernel Image missing; run option 4"
    return 1
  fi
  cp linux/arch/arm64/boot/Image "$KERNEL_OUT"
  info "Copied kernel -> $KERNEL_OUT"
  if [ ! -d "$ROOTFS" ] || [ -z "$(ls -A "$ROOTFS")" ]; then
    echo "Rootfs empty; run option 5 and 6 first"
    return 1
  fi
  rm -f "$INITRD_TAR"
  pushd "$ROOTFS" >/dev/null
  sudo tar -cpf "$INITRD_TAR" . || { popd >/dev/null; echo "Failed to create $INITRD_TAR"; return 1; }
  popd >/dev/null
  sudo chown "$(id -u):$(id -g)" "$INITRD_TAR"
  info "Created initrd -> $INITRD_TAR"

  # kernel direct runner
  cat > "$RUN_QEMU_SERIAL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$WORKDIR/kernel.img"
INITRD="$WORKDIR/rootfs.tar"
if [ ! -f "$KERNEL" ]; then echo "Kernel missing: $KERNEL"; exit 1; fi
if [ ! -f "$INITRD" ]; then echo "Initrd missing: $INITRD"; exit 1; fi
echo "Launching QEMU serial-only (kernel direct). Console appears in this terminal."
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 1024 -nographic -kernel "$KERNEL" -initrd "$INITRD" -append "console=ttyAMA0 root=/dev/ram rw loglevel=7" -serial mon:stdio
EOF
  chmod +x "$RUN_QEMU_SERIAL"

  # U-Boot runner (prefers ELF, auto-build qemu variant if necessary; uses detected CPU)
  cat > "$RUN_QEMU_UBOOT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
UBOOT_DIR="$(cd "$WORKDIR/.." && pwd)/u-boot"
UBOOT_ELF="$UBOOT_DIR/u-boot.elf"
UBOOT_BIN="$UBOOT_DIR/u-boot.bin"
VIRT_IMG="${VIRT_ROOT_IMG:-$WORKDIR/virt-root.img}"
QEMU_LOG="${QEMU_LOG:-$WORKDIR/qemu-firmware.log}"
AUTO_BUILD="${AUTO_BUILD_QEMU_UBOOT:-true}"
QEMU_CPU="${QEMU_CPU_FOR_FIRMWARE:-cortex-a72}"

# prefer ELF then BIN
if [ -f "$UBOOT_ELF" ]; then
  FW="$UBOOT_ELF"
elif [ -f "$UBOOT_BIN" ]; then
  FW="$UBOOT_BIN"
else
  FW=""
fi

if [ -z "$FW" ] && [ "$AUTO_BUILD" = "true" ] && [ -d "$UBOOT_DIR" ]; then
  pushd "$UBOOT_DIR" >/dev/null
  make distclean >/dev/null 2>&1 || true
  if [ -f configs/qemu_arm64_defconfig ]; then
    make qemu_arm64_defconfig >/dev/null 2>&1 || true
  else
    if ls configs/*qemu* >/dev/null 2>&1; then
      cfg=$(ls configs/*qemu* | head -n1)
      make "$(basename "$cfg")" >/dev/null 2>&1 || true
    fi
  fi
  make -j"$(nproc)" >/dev/null 2>&1 || true
  popd >/dev/null
  if [ -f "$UBOOT_DIR/u-boot.elf" ]; then
    FW="$UBOOT_DIR/u-boot.elf"
  elif [ -f "$UBOOT_DIR/u-boot.bin" ]; then
    FW="$UBOOT_DIR/u-boot.bin"
  fi
fi

if [ -z "$FW" ]; then
  echo "No usable U-Boot firmware found. Build QEMU-compatible U-Boot (menu option 3b) and ensure u-boot/u-boot.elf or u-boot/u-boot.bin exists."
  exit 1
fi

if [ ! -f "$FW" ]; then
  echo "Firmware not found: $FW" >&2
  exit 1
fi

if [ -f "$VIRT_IMG" ]; then
  echo "Launching QEMU with firmware and virtio disk (log -> $QEMU_LOG)"
  qemu-system-aarch64 -M virt -cpu "$QEMU_CPU" -m 1024 -nographic -bios "$FW" -drive if=none,file="$VIRT_IMG",format=raw,id=hd0 -device virtio-blk-device,drive=hd0 -serial mon:stdio -d int,cpu_reset -D "$QEMU_LOG"
else
  echo "Launching QEMU with firmware (no virtio disk) (log -> $QEMU_LOG)"
  qemu-system-aarch64 -M virt -cpu "$QEMU_CPU" -m 1024 -nographic -bios "$FW" -serial mon:stdio -d int,cpu_reset -D "$QEMU_LOG"
fi
EOF
  chmod +x "$RUN_QEMU_UBOOT"

  # Debug runner paused for gdb, verbose log, uses detected CPU
  cat > "$RUN_QEMU_UBOOT_DEBUG" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
UBOOT_DIR="$(cd "$WORKDIR/.." && pwd)/u-boot"
UBOOT_ELF="$UBOOT_DIR/u-boot.elf"
UBOOT_BIN="$UBOOT_DIR/u-boot.bin"
VIRT_IMG="${VIRT_ROOT_IMG:-$WORKDIR/virt-root.img}"
QEMU_LOG="${QEMU_LOG:-$WORKDIR/qemu-firmware.log}"
GDB_PORT="${GDB_PORT:-1234}"
QEMU_CPU="${QEMU_CPU_FOR_FIRMWARE:-cortex-a72}"

if [ -f "$UBOOT_ELF" ]; then
  FW="$UBOOT_ELF"
elif [ -f "$UBOOT_BIN" ]; then
  FW="$UBOOT_BIN"
else
  echo "No firmware found for debug; build qemu U-Boot (menu option 3b)." >&2
  exit 1
fi

echo "Starting QEMU paused for gdb on port $GDB_PORT; log -> $QEMU_LOG"
if [ -f "$VIRT_IMG" ]; then
  qemu-system-aarch64 -M virt -cpu "$QEMU_CPU" -m 1024 -nographic -bios "$FW" -drive if=none,file="$VIRT_IMG",format=raw,id=hd0 -device virtio-blk-device,drive=hd0 -serial mon:stdio -S -gdb tcp::${GDB_PORT} -d int,cpu_reset -D "$QEMU_LOG"
else
  qemu-system-aarch64 -M virt -cpu "$QEMU_CPU" -m 1024 -nographic -bios "$FW" -serial mon:stdio -S -gdb tcp::${GDB_PORT} -d int,cpu_reset -D "$QEMU_LOG"
fi
EOF
  chmod +x "$RUN_QEMU_UBOOT_DEBUG"

  info "Generated QEMU serial runners:"
  echo " - $RUN_QEMU_SERIAL   (kernel direct)"
  echo " - $RUN_QEMU_UBOOT    (boot U-Boot as firmware; prefers ELF, auto-build qemu variant if necessary)"
  echo " - $RUN_QEMU_UBOOT_DEBUG (debug: QEMU paused, gdb port open, verbose log)"
}

# -----------------------
# genimage config + generate
# -----------------------
write_genimage_cfg(){
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
  info "genimage config written -> $GENIMAGE_CFG"
}

generate_image(){
  info "Generating SD image via genimage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE/boot"
  if [ -d "$BOOT" ]; then
    cp -r "$BOOT/"* "$STAGE/boot/" 2>/dev/null || true
  fi
  if [ ! -s "$STAGE/boot/u-boot.bin" ]; then
    echo "ERROR: U-Boot missing under $STAGE/boot (u-boot.bin). Build U-Boot and copy u-boot/u-boot.bin into $BOOT then retry."
    return 1
  fi
  rsync -a --exclude=boot/ "$ROOTFS/" "$STAGE/" || true
  mkdir -p "$WORKDIR/tmp"
  rm -f "$IMG"
  genimage --rootpath "$STAGE" --tmppath "$WORKDIR/tmp" --inputpath "$WORKDIR" --outputpath "$WORKDIR" --config "$GENIMAGE_CFG" --loglevel 2
  if [ -f "$IMG" ]; then
    info "genimage finished: $IMG"
    echo "Flash with: sudo dd if='$IMG' of=/dev/sdX bs=4M status=progress conv=fsync"
  else
    echo "genimage failed; inspect $WORKDIR/tmp for logs and errors"
    return 1
  fi
}

generate_image_with_trustzone(){
  info "Building TrustZone artifacts, staging them into boot, signing, and generating rpi.img"
  build_trustzone
  TEE_BIN_CANDIDATES=( "optee_os/out/arm-plat-rpi3/core/tee.bin" "optee_os/out/arm-plat-rpi3/tee.bin" "optee_os/out/arm-plat-rpi3/core/tee.elf" )
  for p in "${TEE_BIN_CANDIDATES[@]}"; do
    if [ -f "$p" ]; then
      cp "$p" "$BOOT/tee.bin"
      info "Copied OP-TEE tee.bin -> $BOOT/tee.bin"
      break
    fi
  done
  if [ -f "u-boot/u-boot.bin" ]; then
    cp u-boot/u-boot.bin "$BOOT/u-boot.bin"
    info "Copied u-boot/u-boot.bin -> $BOOT/u-boot.bin"
  fi
  prepare_boot
  if [ "$ENABLE_SECURE_BOOT" = "true" ]; then
    sign_artifacts
    create_otp_package
  fi
  write_genimage_cfg
  generate_image
}

create_virt_root_img(){
  info "Creating virt-root image at $VIRT_ROOT_IMG (size controlled by VIRT_IMG_MB env or default 512)"
  VIRT_IMG_MB="${VIRT_IMG_MB:-512}"
  rm -f "$VIRT_ROOT_IMG"
  dd if=/dev/zero of="$VIRT_ROOT_IMG" bs=1M count="$VIRT_IMG_MB" status=none
  mkfs.ext4 -F "$VIRT_ROOT_IMG"
  TMPMNT="$(mktemp -d)"
  sudo mount -o loop "$VIRT_ROOT_IMG" "$TMPMNT"
  sudo mkdir -p "$TMPMNT/boot"
  sudo cp -a "$BOOT/." "$TMPMNT/boot/" 2>/dev/null || true
  if [ "${COPY_FULL_ROOTFS:-false}" = "true" ]; then
    sudo cp -a "$ROOTFS/." "$TMPMNT/" 2>/dev/null || true
  fi
  sync
  sudo umount "$TMPMNT"
  rmdir "$TMPMNT"
  info "virt-root image created: $VIRT_ROOT_IMG"
  echo "Use the run-qemu-uboot runner to attach this image to QEMU (runner checks for its presence)."
}

clean_all(){
  info "Cleaning generated artifacts (keeps sources and toolchains)"
  rm -rf "$BOOT" "$ROOTFS" "$STAGE" "$KERNEL_OUT" "$INITRD_TAR" "$RUN_QEMU_SERIAL" "$RUN_QEMU_UBOOT" "$RUN_QEMU_UBOOT_DEBUG" "$WORKDIR/tmp" "$IMG" "$SIGNED_DIR"/* "$VIRT_ROOT_IMG" "$QEMU_LOG"
  mkdir -p "$BOOT" "$ROOTFS"
}

build_all(){
  ensure_toolchains
  clone_sources
  build_uboot
  build_kernel
  build_busybox
  prepare_rootfs
  build_trustzone
  prepare_boot
  produce_qemu_artifacts
  generate_keys
  sign_artifacts
  create_otp_package
  write_genimage_cfg
  generate_image
  info "Full pipeline finished. Use runners to test; flash $IMG for hardware"
}

# -----------------------
# Menu loop
# -----------------------
while true; do
  echo
  echo "======================================"
  echo "RPI5 Secure Build (serial-QEMU, U-Boot qemu support & debug) - workdir: $WORKDIR"
  echo "Detected QEMU CPU for firmware: $QEMU_CPU_FOR_FIRMWARE"
  echo "======================================"
  print_help
  read -rp "Select: " opt
  case "$opt" in
    1) download_toolchains ;;
    2) clone_sources ;;
    3) build_uboot ;;
    3b) build_uboot_qemu ;;
    4) build_kernel ;;
    5) build_busybox ;;
    6) prepare_rootfs ;;
    7) build_trustzone ;;
    8) prepare_boot ;;
    9) produce_qemu_artifacts ;;
    10)
       if [ -x "$RUN_QEMU_SERIAL" ] && [ -x "$RUN_QEMU_UBOOT" ]; then
         echo "Choose runner:"
         echo " 1) Kernel direct serial runner ($RUN_QEMU_SERIAL)"
         echo " 2) Boot U-Boot as firmware ($RUN_QEMU_UBOOT)"
         read -rp "Select runner [1/2]: " r
         if [ "$r" = "1" ]; then "$RUN_QEMU_SERIAL"
         elif [ "$r" = "2" ]; then QEMU_CPU_FOR_FIRMWARE="$QEMU_CPU_FOR_FIRMWARE" "$RUN_QEMU_UBOOT"
         else echo "Invalid runner"
         fi
       else
         echo "Runners missing; run option 9 first to produce artifacts and runners"
       fi
       ;;
    11) generate_keys ;;
    12) sign_artifacts ;;
    13) create_otp_package ;;
    14) write_genimage_cfg ;;
    15) generate_image ;;
    16) generate_image_with_trustzone ;;
    17) create_virt_root_img ;;
    18)
       if [ -x "$RUN_QEMU_UBOOT_DEBUG" ]; then QEMU_CPU_FOR_FIRMWARE="$QEMU_CPU_FOR_FIRMWARE" "$RUN_QEMU_UBOOT_DEBUG"; else echo "Debug runner missing; run option 9 first"; fi
       ;;
    A|a) build_all ;;
    C|c) clean_all ;;
    H|h) print_help ;;
    0) exit 0 ;;
    *) echo "Invalid option" ;;
  esac
done
