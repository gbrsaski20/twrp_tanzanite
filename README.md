# Recovery untuk Redmi Note 14 4G

<div align="center">

**TWRP & OrangeFox · codename `tanzanite` · maintainer [@gbrsaski20](https://github.com/gbrsaski20)**

[![Build TWRP](https://github.com/gbrsaski20/twrp_tanzanite/actions/workflows/build.yml/badge.svg)](https://github.com/gbrsaski20/twrp_tanzanite/actions/workflows/build.yml)
[![Build OrangeFox](https://github.com/gbrsaski20/twrp_tanzanite/actions/workflows/build-orangefox.yml/badge.svg)](https://github.com/gbrsaski20/twrp_tanzanite/actions/workflows/build-orangefox.yml)
[![Device](https://img.shields.io/badge/device-tanzanite-2ea44f)](https://github.com/gbrsaski20/twrp_tanzanite)
[![Android](https://img.shields.io/badge/Android-14-3ddc84?logo=android&logoColor=white)](https://www.android.com/)

</div>

Build recovery `vendor_boot.img` untuk **Xiaomi Redmi Note 14 4G** langsung melalui GitHub Actions. Source disinkronkan dari tree perangkat dan manifest upstream; workflow menyertakan penyesuaian baterai recovery untuk perangkat ini.

> **Perhatian:** image ini hanya untuk Redmi Note 14 4G dengan codename `tanzanite`. Jangan flash ke model lain. Modifikasi partisi berisiko; baca [panduan flash](flash_instructions.txt) dan pastikan file yang diunduh berasal dari build yang benar.

## Pilih recovery

| Recovery | Build | Hasil |
| --- | --- | --- |
| **TWRP** | [Buka workflow TWRP](https://github.com/gbrsaski20/twrp_tanzanite/actions/workflows/build.yml) | Artifact `vendor_boot_twrp_tanzanite` |
| **OrangeFox R12.0** | [Buka workflow OrangeFox](https://github.com/gbrsaski20/twrp_tanzanite/actions/workflows/build-orangefox.yml) | Artifact mengikuti opsi build; dengan battery fix: `vendor_boot_orangefox_tanzanite_gbrsaski20.img` |

### Cara build dan download

1. Buka workflow yang diinginkan dari tabel, lalu pilih **Run workflow** pada branch `main`.
2. Untuk OrangeFox, gunakan branch `12.1` dan biarkan **battery fix** aktif (`on`).
3. Tunggu sampai status run hijau, lalu buka halaman run tersebut.
4. Unduh ZIP pada bagian **Artifacts**, kemudian ekstrak image-nya.

> Build membutuhkan waktu dan kuota GitHub Actions yang cukup. Run yang gagal tidak menghasilkan image yang siap dipakai.

## Flash

Image recovery berada di partisi `vendor_boot`. Ikuti langkah dan perintah khusus perangkat di **[flash_instructions.txt](flash_instructions.txt)**. Jangan menebak nama partisi atau memakai image dari workflow lain. Setelah flash, reboot langsung ke recovery untuk memastikan image terpasang.

## Penyesuaian baterai

Recovery menyertakan `battfixd`, yang menghitung perkiraan SOC dari tegangan dan arus baterai, menampilkan nilainya di recovery, serta menyiapkan seed RTC untuk boot Android berikutnya. Perubahan ini ditujukan untuk kasus persentase baterai meloncat setelah reboot dari recovery.

Build OrangeFox berikutnya menyertakan bridge flashlight MT6789: tombol flashlight diarahkan ke node driver khusus perangkat melalui file kontrol recovery. Perlu diuji kembali pada perangkat setelah image baru terpasang.

Perbaikan ini masih perlu validasi di perangkat, terutama pada boot sistem pertama setelah recovery dan saat baterai rendah. **Belum ada jaminan semua kondisi sudah teratasi.** Catatan investigasi, logika, dan langkah diagnosis tersedia di **[BATTERY.md](BATTERY.md)** dan **[RESEARCH-battery-gauge.md](RESEARCH-battery-gauge.md)**.

## Spesifikasi perangkat

| | |
| --- | --- |
| Perangkat | Xiaomi Redmi Note 14 4G |
| Codename | `tanzanite` |
| Chipset | MediaTek Helio G99 Ultra · MT6789 |
| Platform | Android 14 · vendor boot v4 |
| Recovery | TWRP 12.1 / OrangeFox R12.0 |

## Sumber upstream

- [Recovery device tree](https://github.com/puuuuh/recovery_device_xiaomi_tanzanite) · branch `12.1_aosp`
- [Prebuilt kernel](https://github.com/puuuuh/android_device_xiaomi_tanzanite-kernel) · branch `vanilla`
- [TWRP manifest](https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp) · branch `twrp-12.1`
- [OrangeFox sync](https://gitlab.com/OrangeFox/sync) · branch `fox_12.1`

## Laporkan masalah

Sertakan nama recovery, status dan tautan run Actions, versi yang tampil di layar recovery, serta log yang relevan. Untuk masalah baterai, lihat prosedur pengambilan log di [BATTERY.md](BATTERY.md). Jangan unggah informasi pribadi dari log.
