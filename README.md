# Secure Boot Build System (QEMU + Raspberry Pi 5)

This project provides a **menu‑driven build pipeline** for experimenting with a full secure boot chain:
**TF‑A → OP‑TEE → U‑Boot → Linux → Initramfs → Signed FIT → Bootscript → QEMU / RPi5**.

---

## 📦 Prerequisites

Make sure the following are installed on your host system:

- **Build tools**: `git`, `make`, `gcc`, `wget`, `tar`, `cpio`, `gzip`
- **Cross‑compilers**:
  - `aarch64-linux-gnu-gcc` (preferred for QEMU and RPi5)
  - `arm-linux-gnueabihf-gcc` (optional, for legacy 32‑bit Pis)
  - If not found, the script will **download Arm GNU Toolchains** automatically.
- **Device Tree Compiler**: `dtc`
- **OpenSSL**: for RSA key generation
- **QEMU**: `qemu-system-aarch64` (for BOARD=qemu)

---

## 🌍 Environment Variables

- `BOARD` — target board (`qemu` or `rpi5`). Default: `qemu`
- `OUT` — output directory for build artifacts. Default: `./out/$BOARD`
- `TOOLCHAIN_DIR` — where toolchains are cached. Default: `./toolchains`
- `RPI_BOOT_OUT` — staging directory for Pi 5 boot partition. Default: `./out/rpi5/bootfat`

Example:
BOARD=rpi5 ./build.sh

---

## 🧩 Menu Options
==== Secure Build Menu (qemu) ====
 1. Clone sources              - Fetch U-Boot, TF-A, OP-TEE, Linux
 2. Generate keys              - Create RSA key + DTB for FIT signing
 3. Download/Setup toolchains  - Ensure cross-compilers are ready
 4. Build TF-A                 - Trusted Firmware-A (BL1 + FIP)
 5. Build OP-TEE               - Secure OS binary
 6. Build U-Boot               - Bootloader
 7. Build Linux + stage        - Kernel + DTBs staged into $OUT
 8. Build initramfs            - Minimal initramfs (cpio.gz)
 9. Make bootscript            - boot.txt → boot.scr
10. Make signed FIT source     - fit.its with kernel, ramdisk, DTB
11. Sign FIT                   - fit.itb (RSA signed)
12. Assemble boot artifacts    - Stage fit.itb + boot.scr + uEnv.txt
13. Sign+Assemble+Run QEMU     - (QEMU only)
98. Full RPi5 pipeline         - All steps, stop on error
99. Full QEMU pipeline         - All steps, stop on error + run
 h. Help                       - Show descriptions
 0. Exit

---

## 🚀 Typical Workflows
#QEMU (64‑bit virt machine)
BOARD=qemu ./build.sh

Then in the menu:

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13

Or just run 99 for the full pipeline (auto‑runs QEMU at the end).

#Raspberry Pi 5 (64‑bit bcm2712)
BOARD=rpi5 ./build.sh
Then in the menu:

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12

Or just run 98 for the full pipeline. Artifacts will be staged into $RPI_BOOT_OUT — copy these onto the boot partition of your Pi 5 SD card.

## 🔑 Boot Chain Flow
+---------+     +---------+     +---------+     +---------+     +---------+
|  TF-A   | --> | OP-TEE  | --> | U-Boot  | --> | FIT.itb | --> | Linux   |
| (BL1/FIP)     | (TEE OS)|     | (BL33)  |     | (kernel,|     | Kernel  |
|               |         |     |         |     | ramdisk,|     | + Init  |
|               |         |     |         |     | DTB)    |     | Ramfs   |
+---------+     +---------+     +---------+     +---------+     +---------+

TF‑A: First stage bootloader (BL1) + FIP package

OP‑TEE: Trusted Execution Environment

U‑Boot: Loads and verifies signed FIT

FIT.itb: Contains kernel, initramfs, DTB, all signed

Linux: Boots into kernel + initramfs

## 🛠 Troubleshooting
Toolchain errors: Run option 3 again; it will re‑download if missing.

Missing DTBs: Ensure make dtbs completed in the Linux build.

mkimage not found: Build U‑Boot first; its tools/mkimage is required.

QEMU not booting: Check that fit.itb and boot.scr are staged correctly in $OUT/fatroot.

## ⚠️ Security Note

This pipeline is for educational and prototyping purposes.
For production, use hardened key management, secure storage, and audited build environments.
