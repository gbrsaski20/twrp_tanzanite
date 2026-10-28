# Baterai tanzanite: kenapa recovery bilang 100% dan cara memperbaikinya

Catatan ini merangkum investigasi bug baterai di Redmi Note 14 4G (`tanzanite`,
MT6789) dengan OrangeFox/TWRP di `vendor_boot`. Semua angka di sini hasil
pengukuran di perangkat nyata, bukan asumsi.

Gejala awal yang dilaporkan:

> Baterai nge-jump ke 100% begitu pertama kali boot ke recovery, lalu Android
> ikut 100%. Setelah itu HP mati mendadak di 12% dan tidak pernah sampai 0%.

---

## 1. Ringkasan singkat

Ada **tiga sumber angka baterai yang berbeda** di perangkat ini, dan semuanya
saling bertentangan:

| Pembaca | Node yang dipakai | Nilai saat sel 3.83 V |
|---|---|---|
| TWRP/OrangeFox | `battery/capacity` | 100 |
| Android health HAL | `bms/capacity` | 100 |
| Perhitungan OCV | `bms/voltage_now` + `current_now` | 38 |

Angka 38 yang benar. Dua angka 100 berasal dari **bug skala di driver gauge
kernel** yang membuat gauge selalu boot dengan keyakinan baterai penuh.

Perbaikannya berlapis tiga, dan **ketiganya diperlukan**:

1. Patch DTB `mtk_gauge` — mematikan latch 100% di level display.
2. `battfixd.sh` — daemon di recovery yang menghitung SOC jujur dari OCV.
3. `reset_fg_rtc_set` sekali — membuang state gauge yang korup.

---

## 2. Dua node power_supply, dan kenapa itu penting

```
/sys/class/power_supply/battery/     <- dibaca TWRP (hardcoded)
/sys/class/power_supply/bms/         <- dibaca Android health HAL
```

TWRP tidak bisa dikonfigurasi runtime: `TW_CUSTOM_BATTERY_PATH` adalah define
saat compile. Di recovery, `battery/capacity` tidak bisa dipakai.

Satu jebakan yang mahal: **`battery/current_now` dan `bms/current_now` tandanya
berlawanan** di kernel ini.

```
battery/current_now = -447600   (sedang charging)
bms/current_now     = +449000   (sedang charging)
```

Kalau kode memilih node yang salah, kompensasi IR jadi menambah bukan
mengurangi, dan SOC meleset ~10 poin. Selalu pakai `bms/` dulu.

---

## 3. Akar masalah: `ptim_battery_voltage_get`

Ini temuan utamanya. Di dmesg saat boot:

```
[fgr_dod_init]rtcui=0 case, init_swocv=44670, OCV_to_SOC_c=10000
```

`init_swocv` adalah OCV awal yang dipakai driver. 44670 berarti **4467 mV** —
di atas tegangan baterai penuh (4.4 V). Karena itu SOC dihitung 100%.

Dari mana 4467? Bukan dari DT:

```
fg_custom_init_from_dts swocv_v:38163     <- nilai DT, ini BENAR (3816 mV)
```

Driver mengabaikan DT dan memakai `ptim_battery_voltage_get`:

```
ptim_battery_voltage_get = 4467
init_swocv               = ptim x 10 = 44670 (satuan 0.1 mV) = 4467 mV
```

Dan `ptim` itu **bukan tegangan** — itu kode ADC mentah dengan skala salah.
Buktinya dari dua probe berurutan:

```
vbat 3836 mV / ptim 4467 = 0.8587
vbat 3825 mV / ptim 4451 = 0.8594      <- konsisten sampai 0.08%
```

Rasio konstan 0.859, jadi `ptim = vbat x 1.164`. Driver memakai `ptim` langsung
sebagai mV tanpa mengalikan 0.859, sehingga 3825 mV dibaca **4451 mV** — selisih
626 mV. Itu cukup untuk menggeser SOC dari 38% ke 100%.

Kesimpulan: **bug skala di driver `mt6358-gauge` pada kernel ini** (SuiKernel).
Kernel Mahiru di perangkat yang sama melaporkan angka benar, dan itu yang
menjelaskan perbedaan perilaku antar-kernel yang lama jadi pertanyaan.

Bukti pendukung di dmesg yang sama:

```
[boot_zcv_get] ERROR, _hw_ocv=0  src:1, force use swocv
```

Pembacaan OCV hardware gagal, sehingga driver dipaksa memakai `swocv` yang
salah skala itu. Rantai lengkapnya: ZCV gagal -> pakai swocv -> swocv dari ptim
-> SOC 100%.

Catatan: `info_is_nvram_fail_mode = 1` di unit ini, jadi gauge juga tidak bisa
menyimpan hasil belajar kapasitasnya.

---

## 4. Kenapa patch DTB saja tidak cukup

DTB `mtk_gauge` punya beberapa properti yang mengatur kapan gauge boleh
menampilkan 100%:

```
KEEP_100_PERCENT              = 1
g_FG_PSEUDO100                = [97, 97, 97, 100]
g_FG_PSEUDO100_ov_800_cycle   = [93, 93, 93, 100]
g_FG_charge_PSEUDO100         = [97, 97, 97, 100]
```

Artinya: pada unit dengan 1377 siklus (memakai baris `_ov_800_cycle`), gauge
menampilkan "100%" ketika kapasitas aslinya baru **93%**, lalu menahannya di
sana. Patch `KEEP_100_PERCENT=0` dan semua PSEUDO100 -> 100 mematikan latch itu.

Tapi patch ini **tidak bisa menolong** ketika coulomb counter-nya sendiri sudah
10000 (`OCV_to_SOC_c=10000`). Latch hanya soal tampilan; kalau counter-nya
memang 100%, tidak ada yang bisa ditampilkan selain 100%.

Karena itu patch DTB perlu ditemani lapisan berikutnya.

---

## 5. `battfixd.sh`: angka jujur di recovery

Daemon kecil yang jalan dari `init.rc` recovery. Setiap ~7 detik:

```
OCV = V_terminal - I x R_internal
SOC = interpolasi piecewise dari OCV
```

Lalu hasilnya ditulis ke `/tmp/batt/capacity`, yang dibaca TWRP karena binary-nya
dikompilasi dengan `TW_CUSTOM_BATTERY_PATH := "/tmp/batt"`.

### Kalibrasi RMO

`RMO = 95 mOhm` diukur di perangkat ini (dua transisi arus di 0.46 A dan 0.35 A
memberi 91 dan 103 mOhm). Default generik 60 mOhm membaca ~4% terlalu rendah.

### Filter anti-lompat

Sumber lompatan 2% ternyata **noise arus**, bukan noise tegangan. `current_now`
teramati bergerak 51 mA -> 349 mA dalam satu sesi. Dengan RMO 95 mOhm itu 28 mV,
dan di sekitar 20% kurva bergerak ~8.3 mV per 1%, jadi 28 mV = 3.4 poin noise.

Empat filter menanganinya:

1. **Sampel berpasangan.** Setiap pasangan (V, I) langsung dihitung jadi OCV.
   Versi lama mengambil median V dan median I terpisah, sehingga bisa
   memasangkan V tinggi dengan I rendah dan menghasilkan OCV yang tidak pernah
   terukur.
2. **Prioritas arus kecil.** Kalau ada sampel di bawah 100 mA, itu yang dipakai:
   pada arus ~0, tegangan terminal *adalah* OCV, jadi akurasi RMO tidak lagi
   relevan. Kalau tidak ada, dipakai median dari 5 sampel.
3. **Hysteresis** (`HYST=3`): perubahan di bawah 3 poin diabaikan.
4. **Konfirmasi arah** (`CONFIRM=2`): perubahan besar baru diterapkan setelah
   2 tick berturut-turut searah, jadi spike satu tick tidak sampai ke layar.

Ditambah **creep** (`CREEP=4`): offset kecil yang konsisten selama 4 tick
menggeser 1 poin. Tanpa ini, deadband murni akan membuat tampilan **parkir
permanen** sampai 2 poin dari nilai benar — di bawah artinya HP mati di 2%,
bukan 0%.

Uji tanpa HP: `bash battfix/test_smooth.sh` (17 assertion).

### Seed ke RTC

`battfixd` juga menulis angka jujur ke `mtk-gauge/rtc_ui_soc` setiap tick, tapi
hanya kalau kernel over-report lebih dari 8 poin dan tampilan masih di bawah 95%
(di atas itu kurva terlalu datar untuk dikoreksi). Ini yang membuat Android
mewarisi angka yang benar.

---

## 6. `reset_fg_rtc_set`: memutus ratchet

Diagnosis di atas belum cukup. Masalahnya `rtcui` selalu **0** saat boot
(`rtcui=0 case`), walaupun `battfixd` menulis 38 terus. Artinya cabang
`init_swocv` selalu dipakai, dan ptim yang salah skala selalu menang.

Penyebabnya state gauge tersimpan yang korup. Solusinya sekali saja:

```sh
echo 1 > /sys/class/power_supply/mtk-gauge/reset_fg_rtc_set
```

Penting: **efeknya tidak terlihat di sesi yang sama.** Nilai `rtc_ui_soc` dan
`info_con0_soc` tetap sama sebelum dan sesudah. Perubahan baru muncul setelah
reboot.

Hasil terukur setelah reset + reboot:

```
sebelum : bms/capacity = 100,  Android level = 100
sesudah : bms/capacity = 38,   Android level = 38
          Charge counter = 2041 mAh
```

`2041 / 5350 = 38.1%`, cocok dengan level 38. Berarti coulomb counter benar-benar
di-reset dan di-anchor ulang, bukan cuma tampilan.

Kenapa ini bekerja padahal ptim tetap bug: setelah state korup dibuang, seed
`rtc_ui_soc=38` dari `battfixd` menjadi nilai yang tersimpan dan diwariskan,
sehingga `rtcui` valid dan cabang `init_swocv` tidak lagi dipakai.

**Kombinasi yang menyembuhkan:** resetfg membuang state korup, seed battfixd
menyediakan nilai benar untuk diwariskan. Reset saja akan kembali ke ptim; seed
saja kalah oleh state korup.

---

## 7. Prosedur perbaikan

### Yang dibutuhkan

- Baterai **minimal 40%** (lebih baik 50%) sebelum menyentuh recovery.
- Charger tercolok selama proses, sebagai jaring pengaman.

### Langkah

1. Flash image hasil patch ke **dua slot** — `post_rom_flash.sh` menulis
   `fox_backup.img` ke `vendor_boot_a` dan `vendor_boot_b`:

   ```
   fastboot flash vendor_boot_a OrangeFox-honest-v2-smooth-tanzanite.img
   fastboot flash vendor_boot_b OrangeFox-honest-v2-smooth-tanzanite.img
   ```

2. Boot ke recovery, pastikan angkanya jujur (bukan 100%).

3. Jalankan reset sekali:

   ```
   adb shell "sh /data/local/tmp/battmode.sh resetfg"
   ```

4. Reboot ke **Android**, lalu cek:

   ```
   adb shell "dumpsys battery | grep -E 'level|voltage|Charge counter'"
   adb shell "cat /sys/class/power_supply/bms/capacity"
   ```

   Berhasil kalau `level` mendekati hasil hitung OCV, bukan 100.

5. Cas penuh sampai 100%, lalu **biarkan tercolok 1–2 jam lagi**. Ini fase taper
   yang membuat gauge belajar kapasitas asli sel.

6. Satu siklus penuh untuk mengunci: pakai sampai HP mati sendiri di 0%, lalu cas
   penuh lagi tanpa diputus.

### Jangan lakukan

- **Jangan menulis ke `bms/uisoc`.** Terbukti merusak: coulomb counter jadi 0
  dan capacity jatuh ke 1%. Ini berbeda dari `reset_fg_rtc_set`.
- **Jangan reset FG saat baterai rendah.** Lakukan di kondisi terisi.
- **Jangan menilai angka saat charger tercolok.** Selalu cabut, diamkan 2–3
  menit, baru baca.

---

## 8. Kalau HP mati saat masuk recovery

Ini masalah **terpisah** dari bug persentase, dan bukan bug tampilan.

Dari dmesg, kernel punya ambang berbasis **tegangan**, bukan persentase:

```
[lbat_user_register] name=power throttling, hv=3400, lv1=3250, lv2=3100
```

Boot recovery itu beban berat (layar penuh, CPU tanpa thermal limit). Pada sel
yang sudah 1377 siklus, hambatan dalamnya tinggi, jadi tegangan anjlok di bawah
3.1 V dan PMIC memutus daya seketika. Colok charger -> tegangan ditahan -> hidup
lagi. Itu persis gejalanya.

Perkiraan sisa tegangan saat beban boot ~2 A dengan DCIR ~250 mOhm:

| Baterai | OCV | Sisa |
|---|---|---|
| 21% | 3.67 V | ~3.17 V — mepet cutoff, sering mati |
| 40% | 3.83 V | ~3.33 V — aman |
| 50% | 3.87 V | ~3.37 V — lega |

Jadi: **jangan flash atau boot recovery di bawah 40%.** Ini konsekuensi fisik
dari sel yang aus, tidak bisa diperbaiki dari software.

---

## 9. Peta file

| File | Fungsi |
|---|---|
| `battfix/battfixd.sh` | daemon SOC jujur, dijalankan recovery |
| `battfix/battmode.sh` | probe read-only + eksperimen (`report`, `set`, `resetfg`) |
| `battfix/test_smooth.sh` | uji filter tanpa HP |
| `battfix/ocv.txt` | tabel OCV -> SOC (juga tertanam di battfixd) |
| `tools/patch_fast.py` | bangun ulang vendor_boot dengan battfixd baru |
| `tools/fdt_patch.py` | patch node `mtk_gauge` di DTB |
| `tools/vbimg2.py` | parser/builder vendor_boot, LZ4 legacy, cpio newc |
| `tools/fdt_dump.py` | parser FDT minimal |
| `tools/bootram.py` | buka ramdisk dari boot image `ANDROID!` biasa |

---

## 10. Angka referensi unit ini

Berguna untuk membandingkan kalau ada unit lain:

```
siklus            : 1377
design capacity   : 5350 mAh
RMO terukur       : 95 mOhm
R_FG_VALUE (DT)   : 50
CAR_TUNE_VALUE    : 0
battery_voltage_cali : 0
info_is_nvram_fail_mode : 1
kernel            : SuiKernel 5.10.x
ambang throttle   : 3400 / 3250 / 3100 mV
```
