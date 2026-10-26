# TWRP vendor_boot for Xiaomi Redmi Note 14 4G (tanzanite)

Build TWRP recovery `vendor_boot.img` lewat GitHub Actions — gratis, tanpa perlu PC Linux/WSL2.

## Kebutuhan Storage (WAJIB DIBACA)

Build TWRP dari source AOSP itu **besar**. Angka realistis:

| Komponen | Ukuran |
|----------|--------|
| Ubuntu base (WSL) | ~4 GB |
| Swapfile | 8 GB |
| Source AOSP twrp-12.1 (`.repo` + working tree) | **25-29 GB** |
| `out/` (hasil build recovery) | 8-12 GB |
| ccache (kalau aktif) | 0-5 GB |
| **Subtotal** | **45-58 GB** |
| ext4 reserved (5% default) | +2-3 GB |
| **PRAKTIS BUTUH** | **~60 GB** |

> **50GB TIDAK CUKUP.** Minimum 60 GB, nyaman di 80 GB.

Penghematan yang bisa dipakai:
- Swap 8GB (jangan 16GB — buang space)
- `USE_CCACHE=0` → hemat 5GB
- Hapus `.repo` setelah build sukses kalau gak perlu rebuild

## Cara Pakai (Step by Step)

### 1. Bikin repo GitHub baru
- Pergi ke https://github.com/new
- Nama repo: `twrp-tanzanite-build` (atau apa aja)
- Set **Public** (wajib public biar gratis 2000 menit/bulan)
- Centang "Add a README file"
- Klik **Create repository**

### 2. Upload folder ini ke repo
Copy semua isi folder `twrp_tanzanite/` ke root repo:
```
twrp_tanzanite/
├── .github/workflows/build.yml    <- workflow CI
├── local_manifests/tanzanite.xml  <- device tree config
├── build_twrp_tanzanite.sh        <- build script (untuk WSL2 opsional)
├── flash_instructions.txt         <- cara flash
└── README.md                      <- file ini
```

Cara upload:
- Buka repo di GitHub
- Klik **Add file -> Upload files**
- Drag semua file dari folder `twrp_tanzanite/`
- Commit

atau pakai git:
```bash
cd twrp_tanzanite
git init
git add .
git commit -m "TWRP tanzanite build config"
git branch -M main
git remote add origin https://github.com/USERNAME/twrp-tanzanite-build.git
git push -u origin main
```

### 3. Jalankan build
- Buka repo di GitHub
- Klik tab **Actions**
- Pilih **Build TWRP vendor_boot (tanzanite)** di sidebar kiri
- Klik **Run workflow** (tombol hijau)
- Tunggu 90-150 menit (build di cloud GitHub)

### 4. Download hasilnya
Setelah build selesai (centang hijau):
- Klik run yang selesai
- Scroll ke bawah cari **Artifacts** -> `vendor_boot_twrp_tanzanite`
- Klik download -> dapat `vendor_boot_twrp_tanzanite.zip`
- Extract -> ada `vendor_boot_twrp_tanzanite.img`

Atau kalau auto-release jalan, download dari halaman **Releases**.

### 5. Flash ke HP
```
fastboot flash vendor_boot vendor_boot_twrp_tanzanite.img
fastboot reboot recovery
```

## Device Info
- **Device:** Xiaomi Redmi Note 14 4G
- **Codename:** tanzanite
- **Chipset:** MediaTek Helio G99 Ultra (MT6789)
- **Android:** 14 (HyperOS)
- **Recovery type:** vendor_boot (V4 header)
- **Partition scheme:** Virtual A/B, dynamic partitions, F2FS userdata

## Sources
- Recovery tree: https://github.com/puuuuh/recovery_device_xiaomi_tanzanite (branch: 12.1_aosp)
- Prebuilt kernel: https://github.com/puuuuh/android_device_xiaomi_tanzanite-kernel (branch: vanilla)
- MTK sepolicy: https://github.com/puuuuh/android_device_mediatek_sepolicy_vndr (branch: main)
- TWRP manifest: https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp (branch: twrp-14)

## Features (confirmed working)
ADB, Decryption, Display, Fastbootd, Flashing, MTP, Sideload, USB OTG, SD Card, Touch, Flashlight, Vibrator

## Bug Fix Guide (setelah flash)
Kalau ada bug setelah flash, kita fix bareng. Bug yang umum:

1. **Touch gak jalan** -> kernel module touchscreen gak load. Cek `dmesg` di TWRP terminal.
2. **Decryption fail** -> FBE aes-256-xts. Coba reboot ke system dulu lalu balik ke recovery.
3. **TWRP gak stick** -> system overwrite. Flash ulang lalu `fastboot reboot recovery` langsung.
4. **Black screen** -> panel driver issue. Cek `BOARD_VENDOR_CMDLINE` dan DTB.
5. **Fastbootd gak jalan** -> boot control HAL issue. Cek `android.hardware.boot@1.2-mtkimpl`.

Upload log TWRP (adb shell dmesg / logcat) terus kirim ke sini, kita analisa bareng.
