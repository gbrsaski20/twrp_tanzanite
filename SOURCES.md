# Source Reference — tanzanite

Catatan semua source yang relevan buat Redmi Note 14 4G (tanzanite), biar nanti gampang kalau mau update / fix bug.

## Dipakai Sekarang (default)

### 1. TWRP Recovery Tree
```
https://github.com/puuuuh/recovery_device_xiaomi_tanzanite
branch: 12.1_aosp   (last commit: Mar 2026)
path:   device/xiaomi/tanzanite
```
**Ini satu-satunya TWRP recovery tree untuk tanzanite.** Gak ada alternatif lain.
Isinya: BoardConfig.mk, device.mk, recovery.fstab, 240+ kernel modules, touchscreen firmware (focaltech ft3519t), TEE/gatekeeper blobs.

### 2. Prebuilt Kernel (puuuuh)
```
https://github.com/puuuuh/android_device_xiaomi_tanzanite-kernel
branch: vanilla   (last commit: Mar 2026)
path:   device/xiaomi/tanzanite-kernel
```
Punya patch khusus: `ft3519t` — remove scp_ipidev sigcheck on HyperOS kernel.
**Penting buat touch di HyperOS.**

### 3. MTK Sepolicy
```
https://github.com/puuuuh/android_device_mediatek_sepolicy_vndr
branch: main
path:   device/mediatek/sepolicy_vndr
```

### 4. TWRP Manifest
```
https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp
branch: twrp-12.1   (satu-satunya branch yang ada)
```

---

## Versi TWRP — hasil verifikasi

**Yang kita build: `TW_MAIN_VERSION_STR "3.7.1_12"`**

Artinya: **TWRP 3.7.1** dengan base **Android 12**.

### TWRP 3.7.1 itu versi terbaru? YA.

Release resmi terakhir di twrp.me: **TWRP 3.7.1 — 21 Februari 2024**.
Tidak ada 3.7.2 / 3.8 / versi lebih baru. Jadi versi TWRP-nya **sudah paling baru**.

### Tapi base Android-nya bukan yang terbaru

Perbandingan versi di tiap branch `TeamWin/android_bootable_recovery`:

| Branch | TW_MAIN_VERSION_STR | TWRP | Base Android |
|--------|--------------------|------|--------------|
| `android-12` | `3.6.0_12` | 3.6.0 | Android 12 |
| **`android-12.1`** | **`3.7.1_12`** | **3.7.1** | **Android 12** ← yang kita pakai |
| `android-13` | `3.6.2_12` | 3.6.2 | Android 12 |
| `android-14` | `3.7.0_12` | 3.7.0 | Android 12 |
| `android-14.1` | `3.7.1_14` | 3.7.1 | **Android 14** ← base terbaru |

**Poin penting:** `android-12.1` dan `android-14.1` sama-sama **TWRP 3.7.1**.
Bedanya cuma base Android-nya (`_12` vs `_14`).

Kenapa kita pakai `twrp-12.1`?
1. Manifest `minimal-manifest-twrp/platform_manifest_twrp_aosp` **cuma punya branch `twrp-12.1`**
2. Device tree recovery-nya juga branch `12.1_aosp` — dibuat & dites di base 12.1
3. Fitur decryption udah confirmed working di base ini

**Kapan perlu pindah ke base Android 14:**
- Decryption gagal di device yang pakai keymint Android 14
- Ada masalah dengan crypto/fscrypt policy 2
- Kalau kejadian, harus cari manifest twrp-14 (gak ada di minimal-manifest-twrp) atau bikin manifest sendiri + port device tree-nya

> Kesimpulan: **TWRP-nya sudah versi terbaru (3.7.1)**, cuma base Android-nya 12.
> Untuk tanzanite (HyperOS A14), base 12.1 ini yang memang dipakai komunitas dan terbukti jalan.

---

## Perbandingan Kernel (hasil cek langsung)


| Repo | Branch | Image.gz | modules.load.recovery | Touch module | Aman? |
|------|--------|----------|----------------------|--------------|-------|
| **puuuuh** | `vanilla` | 16,693,099 B | 207 baris | ✅ `lct_tp.ko` + `ft3519t.ko` | ✅ **DEFAULT** |
| **nathanzerogarage** | `vanilla` | 16,691,629 B | 207 baris (**identik puuuuh**) | ✅ ada | ✅ **AMAN** |
| **ryskuys** | `lineage-22.2` | 19,630,219 B | 202 baris (**kurang 5**) | ❌ **TIDAK ADA** | ❌ **JANGAN** |

### Detail temuan

**puuuuh vs nathan:** `modules.load.recovery` **100% identik** (diff kosong), Image.gz beda cuma 1.4 KB.
→ Nathan = **safe drop-in replacement**, cuma lebih baru commit-nya.

**ryskuys (branch `lineage-22.2`):** `modules.load.recovery` **kurang 5 entry**:
```
xiaomi.ko
stub_scp.ko        <- file .ko-nya juga GAK ADA di modules_ramdisk
switch_class.ko
lct_tp.ko          <- TOUCHSCREEN
ft3519t.ko         <- TOUCHSCREEN (FocalTech)
```
File `.ko` touch-nya sebenarnya ada di `modules_ramdisk/`, tapi **gak di-load** karena gak masuk `modules.load.recovery`.
→ Kalau dipakai apa adanya, **touch TWRP pasti mati**.

Kalau tetap mau pakai ryskuys, harus patch dulu:
```bash
# Setelah sync, tambahkan 5 baris ke modules.load.recovery
cd ~/twrp-build/device/xiaomi/tanzanite-kernel
cat >> modules.load.recovery <<'EOF'
xiaomi.ko
switch_class.ko
lct_tp.ko
ft3519t.ko
EOF
# stub_scp.ko gak ada, harus ambil dari repo lain
```
Tapi **gak worth it** — Image.gz-nya beda 3MB (kemungkinan config/built-in driver beda), risikonya besar.

**Commit terakhir:**
- puuuuh: `patch ft3519t to remove scp_ipidev sigcheck on HyperOS kernel`
- nathan: `Update Yuuka prebuilt to latest` (dari MillenniumOS)
- ryskuys: `Update from OS2.0.205.0.VOGEUXM`

> ⚠️ Perhatian: patch `ft3519t scp_ipidev sigcheck` (khusus HyperOS) cuma ada di commit puuuuh.
> Nathan kemungkinan gak punya patch ini. Kalau touch mati di HyperOS pakai kernel Nathan, balik ke puuuuh.

### Kernel 6.12 — ryskuys `lineage-23.1-6.12`
Ada branch dengan kernel 6.12. **JANGAN dipakai** buat TWRP ini — device tree recovery-nya dibikin buat kernel 4.19/5.x MT6789. Bakal gak boot.

---

## Alternatif (buat nanti kalau perlu)

### Kernel versi baru — nathanzerogarage
```
https://github.com/nathanzerogarage/android_device_xiaomi_tanzanite-kernel
branch: vanilla   (last commit: 11 Oct 2026)  <- jauh lebih baru
```
Struktur **identik** dengan puuuuh (Image.gz, dtb/, dtbo.img, modules_dlkm/, modules_ramdisk/, modules.load.recovery) → **drop-in compatible**.
`modules.load.recovery` **sama persis** dengan puuuuh (sudah diverifikasi diff kosong).

Cara pakai:
```bash
MANIFEST=tanzanite-nathan-kernel.xml ./build_twrp_tanzanite.sh
```

**Kapan pakai ini:**
- Bug touch / sensor / charger yang kemungkinan udah difix di kernel baru
- Update dari HyperOS OS2.0.213.0.VOGEUXM
- Kalau module di kernel lama gak load

**Risiko:** patch `ft3519t scp_ipidev sigcheck` (khusus HyperOS) kemungkinan gak ada di versi Nathan. Kalau touch mati setelah pakai kernel ini, balik ke puuuuh.

---

### ROM Device Tree — ryskuys (yang dikirim user)
```
https://github.com/ryskuys/android_device_xiaomi_tanzanite
branch: lineage-21.0   (last push: 5 Oct 2025)  <- LAMA
fork: yes
```
**Bukan recovery tree**, dan udah **ketinggalan setahun**. Gak dipakai.

Yang lebih baru di org ryskuys:
- `android_device_xiaomi_tanzanites` (plural) — `lineage-24.0`, push 20 Oct 2026
- `android_device_xiaomi_tanzanite-kernel` — `lineage-22.2`, push 23 Oct 2026 (tapi touch module bermasalah, lihat tabel atas)

---

### ROM Device Tree — nathanzerogarage
```
https://github.com/nathanzerogarage/android_device_xiaomi_tanzanite
branches: lineage-22.2 (A15) / lineage-23.2 (A16, default) / lineage-24.0 (A17) / lunaris-16.2
last push: 11 Oct 2026
```
**Ini BUKAN recovery tree** — ini device tree buat build ROM (LineageOS). Bahasa: Kotlin (banyak overlay).

**Gunanya buat kita:**
- Referensi fstab / mount point terbaru
- Referensi blobs & firmware yang lebih update
- Referensi init scripts kalau ada masalah boot
- Cek apakah ada perubahan partisi setelah update HyperOS

**Jangan** di-sync ke `device/xiaomi/tanzanite` bareng recovery tree — bakal konflik.

---

### Repo lain di org nathanzerogarage (referensi)
| Repo | Branch | Update |
|------|--------|--------|
| `local_manifests_tanzanite` | lineage-23.2 | Aug 2026 |
| `android_system_fs_fs_mgr_crf` | 17.0 | Oct 2026 |
| `manifest_losf` | lineage-24.0 | Oct 2026 |
| `android_vendor_lineage_losf` | lineage-24.0 | Oct 2026 |
| `android_hardware_xiaomi` | — | — |

---

## Original upstream
```
https://github.com/rexprjkt/android_device_xiaomi_tanzanite
https://github.com/rexprjkt/android_device_xiaomi_tanzanite-kernel
```
Semua repo di atas (puuuuh & nathan) based on rexprjkt.

---

## Cara cek update source

```bash
# Cek commit terakhir tiap repo
cd ~/twrp-build/device/xiaomi/tanzanite && git log -1 --oneline
cd ~/twrp-build/device/xiaomi/tanzanite-kernel && git log -1 --oneline

# Update ke commit terbaru
cd ~/twrp-build && repo sync -c --force-sync
```

Atau cek langsung di GitHub, lihat tanggal commit terakhir.
