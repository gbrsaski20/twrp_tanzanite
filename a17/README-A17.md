# Dekripsi Android 17 di recovery TWRP tanzanite

Catatan teknis untuk dukungan dekripsi FBE pada ROM **Android 17** (Halcyon
`ota-halcyon_tanzanite-17.0-...`, SDK 37, build `CP2A.260605.016`).

## 1. Apa yang dibaca ROM A17 (hasil dump)

Sumber: `vendor_boot.img` Halcyon A17 + `payload.bin` OTA A17 (partisi `vendor`).

| Item | Nilai di ROM A17 |
| --- | --- |
| `/data` | `fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized` |
| Key directory | `keydirectory=/metadata/vold/metadata_encryption` |
| Flag lain | `inlinecrypt`, `fsverity`, `checkpoint=fs`, `reservedsize=128m` |
| `/metadata` | ext4 `data=journal,commit=1` |
| Keymint (vendor) | `android.hardware.security.keymint@1.0-service.mitee` |
| Lib keymint (vendor) | `-V1-ndk.so`, **`-V3-ndk-v35.so`**, **`-V4-ndk.so`**, `rkp-V3-ndk.so` |
| DTB | identik dengan yang dipakai tree (`178665` byte, sha256 sama) |
| Modul kernel | 217 modul, termasuk `mitee.ko`, `tee.ko`, `teeperf.ko` |

## 2. Kenapa TWRP lama gagal

Yang **sudah benar** di image lama (jadi bukan penyebabnya):

- `system/etc/recovery.fstab` sudah memakai FBE v2 + `keydirectory` yang sama.
- DTB identik, daftar modul hampir identik (hanya `xiaomi.ko`, `stub_scp.ko`,
  `switch_class.ko`, `lct_tp.ko`, `ft3519t.ko` yang tidak ikut di
  `modules.load.recovery` TWRP).

Yang **tidak cocok**:

1. **`first_stage_ramdisk/fstab.mt6789`** di image TWRP masih versi lama
   (ada `fscompress`, tanpa `fsverity`). First stage memakai fstab ini untuk
   membuka `/metadata` sebelum TWRP jalan. Kalau flag kriptonya beda,
   `/metadata` gagal di-mount → key FBE tidak terbaca.
2. **Stack TEE/keymint prebuilt** di ramdisk berasal dari vendor stock
   Android 14: service `keymint@1.0-service.mitee` hanya butuh
   `android.hardware.security.keymint-V1-ndk_platform.so`, sementara vendor
   A17 sudah memakai **V3/V4** + TA baru (OTA A17 ikut mem-flash partisi
   `tee`). Service/TA lama tidak bisa membuka key blob yang dibuat TEE baru.
3. **Modul kernel** di ramdisk berasal dari build kernel tree (bukan kernel
   A17). Ukurannya sama tapi hash berbeda untuk 214 dari 217 modul, artinya
   build kernel berbeda; `mitee.ko`/`tee.ko` yang tidak match membuat akses
   TEE gagal.

## 3. Yang dilakukan patch ini

- `a17/fstab.mt6789` → fstab first-stage **persis** dari vendor_boot A17.
- `a17/boardconfig-a17.mk` → `TW_INCLUDE_FBE_METADATA_DECRYPT`,
  `TW_INCLUDE_CRYPTO_FBE`, `TW_USE_FSCRYPT_POLICY=2`, `TW_FORCE_KEYMASTER_VER`.
- `a17/init.append.rc` → fragmen init yang **di-append** (bukan menimpa rc):
  keymint juga dipicu dari `servicemanager.ready` (AIDL, bukan cuma
  `hwservicemanager`), plus service `crypto-diag`. Di-append supaya patch
  battfix/flashlight di rc tidak hilang.
- `a17/root/system/bin/crypto-diag.sh` → menulis `/tmp/crypto-diag.log`:
  properti kripto, mount, modul TEE, status service HAL, potongan
  logcat/dmesg.
- `a17/root/system/bin/format-data.sh` → format `/data` manual (lihat bagian 5).
- `tools/repack_vendor_boot.py` → merakit `vendor_boot` recovery di atas
  basis `vendor_boot` A17: fstab A17 + **217 modul A17** + overlay, rootfs
  TWRP tetap. Hasil build lokal: 62.394.368 byte (partisi 64 MiB), verifikasi
  cpio + DTB OK.
- `tools/pull_a17_stack.sh` → menarik `keymint service`, `tee-supplicant`,
  `libteecli.so`, gatekeeper, dan seluruh `mitee/ta/*.ta` **dari ROM A17 di
  HP** ke `a17/prebuilt/vendor/`. Selama folder itu kosong, build masih
  memakai prebuilt A14 (poin 2 di atas belum tuntas).
- Workflow **TWRP dan OrangeFox** sama-sama menjalankan langkah
  “Patch device tree (A17 crypto)”. Sebelumnya hanya TWRP yang dipatch,
  jadi build OrangeFox tetap rusak walau TWRP sudah benar.

## 4. OrangeFox: “gabisa format data”

“Format Data” di TWRP/OrangeFox mengerjakan **dua** hal: membuat ulang
filesystem `/data`, lalu minta `keystore2` → keymint/TEE membuat kunci FBE
baru. Kalau keymint gagal (stack TEE lama vs TEE A17), langkah kedua gagal dan
UI melaporkan “Unable to format data” — padahal `make_f2fs` sendiri bisa jadi
sukses.

Urutan yang benar saat ini:

1. Flash image A17 (TWRP atau OrangeFox dari workflow yang sudah dipatch).
2. Kalau tombol Format Data masih gagal, format manual dari terminal/adb:
   ```
   sh /system/bin/format-data.sh                  # /data saja
   sh /system/bin/format-data.sh --wipe-metadata  # + buang kunci metadata
   ```
   Script ini mencetak rc tiap langkah dan menulis `/tmp/format-data.log`,
   jadi kelihatan apakah yang gagal filesystem atau kuncinya.
3. Reboot ke recovery → coba `Mount /data`.
4. Kalau mount masih gagal → ambil `/tmp/crypto-diag.log` (bagian 4) dan
   lengkapi stack TEE A17 lewat `tools/pull_a17_stack.sh`.

Catatan: `--wipe-metadata` menghapus kunci metadata. Semua isi `/data` hilang
(memang tujuannya), dan ROM akan membuat kunci baru saat boot pertama. Pakai
kalau kunci lama sudah tidak bisa dibuka TEE (habis ganti ROM / partisi `tee`
ter-flash ulang).

## 5. Urutan pengerjaan

1. Build/flash image A17 (workflow TWRP/OrangeFox, atau
   `tools/repack_vendor_boot.py` untuk build lokal).
2. Boot ke recovery, coba buka `/data`, lalu:
   ```
   adb pull /tmp/crypto-diag.log
   ```
3. Kalau log menunjukkan keymaster/keymint error atau TA gagal load:
   ```
   ./tools/pull_a17_stack.sh          # HP harus di TWRP, /vendor ter-mount
   git add a17/prebuilt && git commit -m "a17: TEE stack dari ROM A17" && git push
   ```
   lalu build ulang — langkah "A17 crypto overlay" di kedua workflow otomatis
   memakai stack baru itu.
4. Kalau log menunjukkan `/metadata` gagal di-mount, cek `checkpoint=fs` pada
   `/data` (fs kotor/checkpoint aktif) dan jalankan dari TWRP:
   ```
   e2fsck -f /dev/block/by-name/metadata
   ```

## 6. Batasan

- Semua perubahan di atas belum diuji di perangkat (tidak ada akses HP dari
  sisi build). Yang bisa dipastikan di sini: struktur image valid, fstab dan
  modul berasal dari ROM A17, dan diagnostik akan menunjukkan titik gagal
  yang sebenarnya.
- Jangan flash ke device selain `tanzanite`.
