# Penelitian: bug fuel gauge MT6358 di Redmi Note 14 4G (`tanzanite`)

**Status dokumen:** ringkasan investigasi lengkap, disusun untuk diserahkan ke
AI/peneliti lain.
**Tanggal:** 1 November 2026
**Perangkat uji:** 1 unit fisik, dipakai harian.

---

## 0. Cara membaca dokumen ini

Setiap klaim diberi label:

| Label | Arti |
|---|---|
| **[UKUR]** | Hasil pembacaan langsung dari perangkat, angkanya ada di dokumen |
| **[TURUNAN]** | Kesimpulan logis dari angka [UKUR], perhitungannya bisa diulang |
| **[DUGAAN]** | Hipotesis yang belum dikonfirmasi. **Jangan diperlakukan sebagai fakta** |
| **[GUGUR]** | Hipotesis yang sudah diuji dan terbukti salah. Jangan diulang |

Angka tanpa satuan jelas selalu diberi satuan. Tegangan di sysfs satuannya
mikrovolt (uV), di tabel OCV satuannya milivolt (mV), di `init_swocv` satuannya
0.1 mV.

---

## 1. Lingkungan

| Item | Nilai |
|---|---|
| Perangkat | Redmi Note 14 4G, codename `tanzanite` |
| SoC | MediaTek MT6789 |
| PMIC | MT6358 / MT6366 |
| Driver gauge | `mt6358-gauge` (`compatible = "mediatek,mt6358-gauge"`) |
| Baterai | Li-poly, design capacity **5350 mAh**, **1377 siklus** |
| Slot | A/B, recovery ada di `vendor_boot` |
| Recovery | OrangeFox R12.0 A12+ AOSP Unofficial (TWRP-based) |
| Kernel saat bermasalah | SuiKernel `5.10.255` ("HayaseYuuka") |
| Kernel yang dilaporkan normal | `5.10.247` ("Mahiru") |
| ROM | AxionOS |

Recovery tidak membawa kernel sendiri. Kernel berasal dari `boot.img`; yang
kita ubah adalah `vendor_boot` (ramdisk recovery + DTB).

**Penting:** DTB di `vendor_boot` dipakai **baik oleh recovery maupun Android**.
Ini sudah dibuktikan — patch `KEEP_100_PERCENT` di DTB `vendor_boot` ikut
mengubah perilaku gauge di Android. Jadi DTB adalah jalur pengaruh yang sah
terhadap Android, sedangkan ramdisk recovery tidak.

---

## 2. Gejala

### 2.1 Gejala awal (sebelum ada perbaikan apa pun)

> Begitu pertama kali flash recovery dan boot ke OrangeFox, baterai langsung
> 100%. Masuk Android juga 100%. Setelah itu HP mati mendadak di 12% dan tidak
> pernah mau sampai 0%.

### 2.2 Gejala setelah perbaikan v1/v2 (yang masih tersisa)

- Di dalam OrangeFox: **sudah benar**, angka mengikuti kenyataan.
- Dari OrangeFox → "Reboot System" → Android: **kadang benar, kadang loncat**.
- Dari OrangeFox → "Power Off" → tekan tombol power → Android: **selalu benar**.
- Menyalakan HP dengan charger sudah tercolok: **loncat**.
- Reboot dari Android ke Android: **benar**.

### 2.3 Pola yang ditemukan user (ini yang paling berharga)

> "Pas baterai benar-benar habis, padahal di OrangeFox sudah 0%, begitu reboot
> system dari OrangeFox dia loncat ke 80%+."

Dan pada percobaan lain di 22%, reboot system dari OrangeFox **tidak** loncat.

**[TURUNAN]** Jadi pemicunya bukan persentase tertentu, melainkan **nilai 0**.

---

## 3. Node sysfs yang relevan

```
/sys/class/power_supply/battery/     <- dibaca TWRP (path hardcoded saat compile)
/sys/class/power_supply/bms/         <- dibaca Android health HAL
/sys/class/power_supply/mtk-gauge/   <- node internal driver, banyak yang RW
```

TWRP tidak bisa diarahkan ulang saat runtime: `TW_CUSTOM_BATTERY_PATH` adalah
`#define` saat build. Karena itu kita menulis nilai hasil hitungan sendiri ke
`/tmp/batt/capacity`, yang memang dibaca TWRP.

### 3.1 Jebakan tanda arus **[UKUR]**

```
battery/current_now = -447600   (sedang charging)
bms/current_now     = +449000   (sedang charging)
```

Tandanya **berlawanan** di kernel ini. Kalau kode memilih node yang salah,
kompensasi IR jadi menambah bukan mengurangi, dan SOC meleset ~10 poin.
Aturan: **selalu pakai `bms/` lebih dulu.**

### 3.2 Node `mtk-gauge` yang penting

| Node | Perm | Catatan |
|---|---|---|
| `rtc_ui_soc` | rw | UI SOC yang diwariskan antar-boot. **0 = "tidak ada data"** |
| `info_con0_soc` | rw | SOC internal driver, terpisah dari `rtc_ui_soc` |
| `ptim_battery_voltage_get` | ro | **Sumber bug utama.** Kode ADC, bukan tegangan |
| `ptim_resist_get` | ro | Selalu `0` di unit ini **[UKUR]** |
| `boot_zcv_get` | ro | ZCV saat boot; sering `0` **[UKUR]** |
| `zcv_get` | ro | Selalu `0` **[UKUR]** |
| `info_is_nvram_fail_mode` | rw | `1` di unit ini **[UKUR]** |
| `reset_fg_rtc_set` | w | Membuang state FG tersimpan |
| `coulomb_get` | ro | Coulomb counter mentah |
| `average_current_get` | ro | Satuannya belum jelas, belum dipakai |
| `uisoc_update_type` | — | **Tidak ada** di kernel ini |

---

## 4. Akar masalah

### 4.1 Rantai sebab-akibat **[UKUR] + [TURUNAN]**

```
[UKUR]  ptim_battery_voltage_get = 4467     saat vbat = 3836 mV
[UKUR]  ptim_battery_voltage_get = 4451     saat vbat = 3825 mV
[TURUNAN] rasio 3836/4467 = 0.8587
[TURUNAN] rasio 3825/4451 = 0.8594          konsisten sampai 0.08%
[TURUNAN] jadi ptim = vbat x 1.164  (skala salah, bukan tegangan)

[UKUR]  init_swocv = ptim x 10  (satuan 0.1 mV)
[UKUR]  init_swocv=44670  -> 4467 mV   padahal sel 3825 mV
[UKUR]  init_swocv=42510  -> 4251 mV   padahal sel ~3700 mV (baterai 22%)
[TURUNAN] selisih ~550-640 mV, selalu ke atas
[TURUNAN] 4251 mV di kurva OCV = 82.57%
```

### 4.2 Mengapa driver memakai `ptim`, bukan nilai DT

Di dmesg ada dua nilai OCV yang berbeda:

```
fg_custom_init_from_dts swocv_v:38163      <- dari DT, ini BENAR (3816 mV)
[fgr_dod_init]rtcui=0 case,init_swocv=44670 <- yang dipakai, ini SALAH
```

**[UKUR]** Driver mengabaikan `swocv_v` dari DT dan memakai `init_swocv`
turunan `ptim`.

Pemicunya ada di baris berikutnya **[UKUR]**:

```
[boot_zcv_get] ERROR, _hw_ocv=0  src:1, force use swocv
```

Pembacaan OCV hardware gagal (`_hw_ocv = 0`), sehingga driver dipaksa memakai
`swocv` — dan `swocv` di sini adalah `ptim` yang salah skala.

**[DUGAAN]** `ptim_resist_get = 0` mungkin penyebab skala salahnya. Nilai itu
read-only, jadi tidak bisa dikoreksi dari userspace.

### 4.3 Cabang `rtcui=0`

Driver punya cabang khusus saat `rtc_ui_soc` bernilai 0:

```
[fgr_dod_init]rtcui=0 case,init_swocv=...,OCV_to_SOC_c=...
```

**[TURUNAN]** Nama cabangnya sendiri menyatakan bahwa **0 diperlakukan sebagai
"tidak ada data"**, bukan "baterai kosong". Saat masuk cabang ini, driver
memakai `init_swocv` yang salah → **~82%**.

### 4.4 Konsekuensi: target lompatan selalu sama

**[UKUR]** `init_swocv` pada dua pengukuran berbeda:

| Kondisi nyata | `init_swocv` | `OCV_to_SOC_c` |
|---|---|---|
| 38% | 44670 (4467 mV) | 10000 = 100.00% |
| 22% | 42510 (4251 mV) | 8257 = 82.57% |

**[TURUNAN]** Kernel **selalu** memulai setiap boot di kisaran 82-100%,
tergantung tegangan. Yang menentukan apakah user melihatnya adalah apakah
`rtc_ui_soc` berisi nilai valid atau tidak.

Ini juga menjelaskan keluhan "loncat random jadi 80%+" — angka 80-an itu
**bukan random**, itu hasil konversi `ptim` yang selalu ~15% terlalu tinggi.

---

## 5. Model perilaku (yang menjelaskan semua gejala)

```
boot
 |
 +-- rtc_ui_soc valid (1..100)?
      |
      +-- YA  -> driver pakai nilai itu -> ANGKA BENAR
      |
      +-- TIDAK (0) -> pakai init_swocv = ptim x 10 -> ~82% -> LOMPAT
```

Kapan `rtc_ui_soc` berisi 0?

1. **Baterai benar-benar habis.** Daemon menulis 0 dengan jujur → tersimpan 0 →
   boot berikutnya dianggap "tidak ada data" → 82%. **[TURUNAN, cocok dengan
   laporan user]**
2. **Boot pertama setelah flash.** Belum ada yang menulis.
3. **Sesi sebelumnya Android.** **[UKUR]** Dmesg dari sesi recovery yang
   didahului Android menunjukkan `rtcui=0`, artinya Android tidak mewariskan
   nilai. Ini yang belum jelas mekanismenya (lihat §9).

Kapan benar?

1. Sesi sebelumnya recovery dan baterai tidak kosong.
2. Power off dari recovery, lalu tombol power (cold boot).

---

## 6. Perbaikan yang sudah diterapkan

Perbaikan berlapis tiga, dan **ketiganya diperlukan**.

### 6.1 Lapisan 1 — patch DTB `mtk_gauge`

```
KEEP_100_PERCENT              : 1 -> 0
g_FG_PSEUDO100                : [97,97,97,100] -> [100,100,100,100]
g_FG_PSEUDO100_100_300_cycle  : [95,95,95,100] -> [100,100,100,100]
g_FG_PSEUDO100_300_800_cycle  : [93,93,93,100] -> [100,100,100,100]
g_FG_PSEUDO100_ov_800_cycle   : [93,93,93,100] -> [100,100,100,100]
g_FG_charge_PSEUDO100         : [97,97,97,100] -> [100,100,100,100]
```

Alasannya: pada unit 1377 siklus, gauge memakai baris `_ov_800_cycle` yang
berisi 93. Artinya "100%" ditampilkan saat kapasitas asli baru 93%, lalu
**ditahan** di sana oleh `KEEP_100_PERCENT=1`. Patch ini mematikan latch itu.

**[UKUR]** Patch ini **tidak cukup sendirian**: kalau coulomb counter-nya sudah
`10000`, tidak ada yang bisa ditampilkan selain 100%.

### 6.2 Lapisan 2 — `battfixd.sh` di recovery

Daemon yang dijalankan dari `init.rc` recovery. Setiap ~6 detik:

1. Baca `bms/voltage_now` dan `bms/current_now` **berpasangan**, 5 sampel.
2. Kalau ada sampel dengan |I| ≤ 100 mA, pakai sampel itu — pada arus ~0,
   tegangan terminal **adalah** OCV, jadi akurasi `RMO` tidak lagi penting.
3. Kalau tidak ada, ambil median dari kelima pasangan.
4. Kompensasi IR: `OCV = V_terminal - I x RMO`, dengan `RMO = 95 mΩ`.
5. Cari SOC di tabel OCV (piecewise linear).
6. Filter tampilan: deadband + konfirmasi arah + creep.
7. Tulis hasilnya ke `/tmp/batt/capacity` (yang dibaca TWRP).
8. Tulis juga ke `mtk-gauge/rtc_ui_soc` supaya diwariskan ke boot berikutnya.

Tabel OCV yang dipakai (mV → %):

```
4400 100 | 4350 99 | 4300 96 | 4250 92 | 4200 87 | 4150 82
4100 76  | 4050 70 | 4000 64 | 3950 58 | 3900 51 | 3850 44
3800 37  | 3750 30 | 3700 24 | 3650 18 | 3600 13 | 3550 9
3500 6   | 3450 3  | 3400 1  | 3350 0
```

**Kalibrasi `RMO`:** 95 mΩ dipilih dari pengukuran pada ~0.45 A. Kemiringan
kurva di sekitar 20% adalah ~8.3 mV per 1% SOC, jadi kesalahan 100 mA pada
pembacaan arus menghasilkan ~9.5 mV = ~1.1 poin SOC.

### 6.3 Lapisan 3 — `reset_fg_rtc_set` sekali

**[UKUR]** Sebelum: `battery/capacity = 100`, `bms/capacity = 100`, Android
`level: 100`.
**[UKUR]** Sesudah `echo 1 > reset_fg_rtc_set` lalu reboot:
`bms/capacity = 38`, Android `level: 38`, `Charge counter: 2041 mAh`.
**[TURUNAN]** `2041 / 5350 = 38.1%` — cocok persis dengan level 38. Berarti
coulomb counter benar-benar di-reset dan di-anchor ulang, bukan cuma tampilan.

**[UKUR]** Efeknya **tidak langsung** — baru muncul setelah reboot.

**[TURUNAN]** Mekanisme yang masuk akal: reset membuang state FG korup yang
membuat `rtcui` selalu invalid; setelah itu seed dari `battfixd` menjadi nilai
yang tersimpan dan diwariskan, sehingga `rtcui` valid dan cabang `init_swocv`
tidak dipakai lagi. Reset saja tanpa seed akan kembali ke `ptim`; seed saja
tanpa reset kalah oleh state korup.

### 6.4 Lapisan 4 (v3) — jangan pernah menyimpan 0

Ini perbaikan untuk gejala §2.3.

```sh
SEED_MIN=1
SEED_VAL=$DISP
[ "$SEED_VAL" -lt "$SEED_MIN" ] && SEED_VAL=$SEED_MIN
```

Nilai asli 0% disimpan sebagai **1**. Satu poin bohong, dibanding 82 poin bohong.

**[UKUR]** Diuji lokal: `disp=0/kernel=82 -> tulis 1`; `disp=22/kernel=82 ->
tulis 22`; `disp=0/kernel=5 -> tidak menulis`; `disp=96 -> tidak menulis`
(di atas `SEED_CEIL`).

---

## 7. Hasil yang sudah terverifikasi di perangkat

| Uji | Hasil |
|---|---|
| Boot pertama setelah flash v1 | **4%**, bukan 100% ✅ |
| Reboot ke recovery | 7%, Android juga 7% ✅ |
| Round-trip dari Android saat charging | tidak loncat ✅ |
| `resetfg` + reboot | 100% → 38%, tahan reboot sistem ✅ |
| Android stabil di 21% | tidak ada pergerakan anomali ✅ |
| v2 (filter halus) | creep 1 poin setelah 4 tick, bukan lompat 2 poin ✅ |
| v3 (jangan simpan 0) | **belum di-flash** ⏳ |

---

## 8. Hipotesis yang sudah gugur — JANGAN DIULANG

| Hipotesis | Kenapa gugur |
|---|---|
| **[GUGUR]** `system/bin/charger` hilang di AOSP recovery penyebabnya | `init.rc` OrangeFox tidak pernah menjalankan `charger`; Evolution X dan Project Infinity `vendor_boot` tidak punya charger sama sekali; stock HyperOS dan engrom **punya** `service charger` dan tetap kena bug |
| **[GUGUR]** DT gauge berbeda dari stock | Dibandingkan langsung: `bootmode`, `SHUTDOWN_1_TIME`, `R_FG_VALUE`, `CAR_TUNE_VALUE`, `PMIC_MIN_VOL`, `SHUTDOWN_GAUGE0_VOLTAGE` **semua identik** dengan stock HyperOS `OS1.0.2.0.UOGEUXM`. Yang beda hanya tabel PSEUDO100 (bawaan build) dan `KEEP_100_PERCENT` (patch kita) |
| **[GUGUR]** `reset_fg_rtc_set` tidak berefek | Sempat disimpulkan begitu karena sebelum/sesudah identik dalam satu sesi. Ternyata efeknya baru muncul **setelah reboot** |
| **[GUGUR]** Tulis `rtc_ui_soc` dari userspace tidak berpengaruh | Salah. Satu tulisan kalah oleh interrupt FG (~3 s), tapi tulisan berulang tiap 5 s menang |
| **[GUGUR]** Kernel Mahiru vs SuiKernel drivernya beda banyak | Perbandingan string kernel: 160 vs 159 string terkait baterai, bedanya hanya fragmen nama simbol. Drivernya praktis sama |
| **[GUGUR]** Menulis `bms/uisoc` untuk koreksi | **Berbahaya.** Ini mereset coulomb counter dan menjatuhkan capacity ke 1% |
| **[GUGUR]** `ptim` itu data tersimpan yang bisa dibuang | Rasio terhadap tegangan konsisten 0.859 pada dua probe berbeda, jadi ini pembacaan ADC hidup, bukan data lama |

---

## 9. Pertanyaan terbuka

1. **Mengapa `rtcui` sering 0 padahal sesi recovery sebelumnya menulis nilai
   valid?**
   **[UKUR]** Dmesg sesi recovery yang didahului Android: `rtcui=0`.
   **[UKUR]** Di sesi lain, readback `rtc_ui_soc` menunjukkan nilai yang kita
   tulis (39/40) berhasil.
   **[DUGAAN]** Handler simpan di driver mungkin terpasang di `pm_power_off`
   (hanya jalan saat power off) dan bukan di `.shutdown` (jalan saat reboot).
   Ini yang perlu dikonfirmasi dari source `mt6358-gauge.c`.

2. **Apakah `SHUTDOWN_1_TIME = 30` berperan?**
   Properti DT ini ada dan nilainya 30, sama dengan stock. Artinya belum tentu
   relevan, tapi belum diuji.

3. **Apakah `bootmode = 0x50` berperan?**
   Nilai statis di DT, sama dengan stock. Bit 4 = `KERNEL_POWER_OFF_CHARGING`,
   bit 6 = `RECOVERY`. **[DUGAAN]** LK mungkin menimpanya saat boot; kalau tidak,
   driver bisa salah mengira mode boot. Belum diuji.

4. **Mengapa kernel Mahiru melaporkan benar?**
   Perbedaan yang tersisa hanya versi (5.10.247 vs 5.10.255). Belum ada
   perbandingan disassembly pada fungsi konversi ADC.

5. **Bisakah bug skala `ptim` dikoreksi?**
   `ptim_resist_get` read-only dan selalu 0. **[DUGAAN]** Ini penyebab skala
   salahnya. Kalau benar, perbaikannya harus di kernel, bukan userspace.

6. **Apakah `average_current_get` lebih stabil dari `bms/current_now`?**
   Node ini ada dan read-only, tapi satuannya belum jelas (2273 vs 63000 uA
   pada pembacaan berbeda). Belum dipakai.

---

## 10. Jebakan operasional — jangan lakukan

1. **Jangan menulis `bms/uisoc`.** Mereset coulomb counter, capacity jatuh ke 1%.
2. **Jangan reset FG saat baterai rendah.** Justru mengulang gejala "nyangkut di
   1%". Lakukan hanya saat 100% dan tercolok.
3. **Jangan menilai angka saat charger tercolok.** Cabut, diamkan 2 menit, baru
   baca. Port USB PC hanya ~500 mA, arusnya bolak-balik `Charging`/`Discharging`.
4. **Jangan boot ke recovery di bawah 40%.** Lihat §11.
5. **Jangan pakai `/tmp` di recovery ini.** Bukan tmpfs, dan nama file dipotong
   ke 8.3. Pakai `/data/local/tmp/`.
6. **Jangan andalkan `su` di recovery.** Tidak ada; recovery sudah root.

---

## 11. Kenapa HP mati saat boot ke recovery di bawah 40%

**[UKUR]** Dari dmesg:

```
[lbat_user_register] name=power throttling, hv=3400, lv1=3250, lv2=3100
```

**[TURUNAN]** Cutoff berbasis **tegangan**, bukan persentase: throttle di
3400 mV dan 3250 mV, mati di **3100 mV**.

**[TURUNAN]** Boot recovery itu beban berat (layar penuh, CPU kencang, tanpa
thermal limit). Sel 1377 siklus punya hambatan dalam tinggi, jadi tegangan
anjlok di bawah cutoff → mati seketika. Colok charger menahan tegangan → hidup
lagi. Ini persis gejala yang dilaporkan.

Perkiraan dengan `RMO = 95 mΩ` dan beban boot ~2 A:

| Baterai | OCV | Sisa setelah sag 2 A | Aman? |
|---|---|---|---|
| 21% | 3670 mV | ~3170 mV | mepet, sering mati |
| 40% | 3830 mV | ~3330 mV | aman |
| 50% | 3870 mV | ~3370 mV | lebih lega |

**[TURUNAN]** Kalibrasi **tidak** memperbaiki ini. Kalibrasi mengubah angka,
bukan hambatan dalam sel.

---

## 12. Kalibrasi: yang realistis dan yang tidak

**Yang bisa diperbaiki kalibrasi:** Android berhenti bilang 21% saat aslinya
14%. User berhenti tertipu.

**Yang tidak bisa:** menghentikan HP mati saat boot recovery di bawah 40%.

Prosedur: cas sampai 100%, **biarkan tercolok 1-2 jam lagi** setelah angka 100%
(fase taper — ini yang membuat gauge belajar kapasitas asli), lalu pakai normal
sampai HP mati sendiri di 0%, lalu cas penuh lagi tanpa diputus. Satu-dua siklus.

**[UKUR]** Sampai sekarang `Maximum capacity` masih 5350 mAh = design capacity,
padahal sel 1377 siklus. Artinya gauge belum belajar kapasitas aslinya. Ini yang
membuat angkanya masih ~3-6 poin optimis.

---

## 13. Lampiran: data mentah

### 13.1 Dmesg khas saat bug

```
[    5.604488] mt6358_gauge_probe: starts
[    5.609807] fg_swocv_v prop == NULL, len=0
[    5.610432] fg_swocv_i prop == NULL, len=0
[    5.611714] fg_check_lk_swocv swocv_v:0 swocv_i:0 shutdown_time:0
[    5.612594] fgauge_get_profile_id: battery id  = 0
[    6.530518] fgauge_get_cycle_count: cycle count  = 1377
[    6.531834] fg_custom_init_from_dts swocv_v:38163 swocv_i:-14 shutdown_time:1
[    6.661372] [fgr_dod_init]rtcui=0 case,init_swocv=44670,OCV_to_SOC_c=10000 ui:[10000 10000] con0_soc=[16 0]
[    6.668855] gauge_coulomb_before_reset car=11281
[    6.669740] [fgauge_hw_reset]: start
[    6.672036] [fgauge_hw_reset]: end
[    6.677098] [fgr_dod_init]fg_c_d0[10000 44613 0] d0_sel[0] c_soc[0 10000] ui[10000 10000] soc[10000] con0[ui 0 16]
[    6.734423] [battery_init]: enable Kernel mode Gauge
[   16.562848] car[2,269,-269,541,-270] tmp:38 soc:100 uisoc:100 vbat:3827 ibat:1193 baton:565 algo:1 gm3:0 0 0 0 0,boot:2
[  367.129725] [boot_zcv_get] ERROR, _hw_ocv=0  src:1, force use swocv
```

### 13.2 Dmesg pada 22% (setelah perbaikan)

```
[   10.911705] [fgr_dod_init]rtcui=0 case,init_swocv=42510,OCV_to_SOC_c=8257 ui:[8257 8257] con0_soc=[1 0]
[   10.928337] [fgr_dod_init]fg_c_d0[8258 42512 1742] d0_sel[0] c_soc[1742 8258] ui[8257 8257] soc[8258] con0[ui 0 1]
```

Perhatikan: `soc[8258]` = 82.58%, padahal baterai 22%. `c_soc[1742 8258]`
menunjukkan driver punya dua kandidat (17.42% dan 82.58%) dan `d0_sel[0]`
memilih indeks 0, tapi nilai akhir yang dilaporkan tetap 8258.

### 13.3 Perbandingan DTB vs stock HyperOS

| Properti | Stock `OS1.0.2.0.UOGEUXM` | OrangeFox |
|---|---|---|
| `bootmode` | 0x50 | 0x50 |
| `SHUTDOWN_1_TIME` | 30 | 30 |
| `R_FG_VALUE` | 5 | 5 |
| `CAR_TUNE_VALUE` | 101 | 101 |
| `PMIC_MIN_VOL` | 33500 | 33500 |
| `SHUTDOWN_GAUGE0_VOLTAGE` | 34000 | 34000 |
| `DIFFERENCE_FULLOCV_ITH` | 200 | 200 |
| `POWERON_SYSTEM_IBOOT` | 500 | 500 |
| `FG_METER_RESISTANCE` | 70 | 70 |
| `COM_FG_METER_RESISTANCE` | 100 | 100 |
| `KEEP_100_PERCENT` | 1 | 1 (dipatch jadi 0) |
| `g_FG_PSEUDO100_100_300_cycle` | 97,97,97,100 | 95,95,95,100 |
| `g_FG_PSEUDO100_ov_800_cycle` | 93,93,93,100 | 93,93,93,100 |

### 13.4 Berkas

| Berkas | Isi |
|---|---|
| `battfixd.sh` | Daemon recovery (15.146 byte) |
| `battmode.sh` | Probe read-only + mode `set`/`restore`/`resetfg` |
| `cek_batre.bat` | Diagnosa lengkap dari Windows |
| `cek_boot.bat` / `cek_boot.sh` | Membaca & mengklasifikasi baris `fgr_dod_init` |
| `_t/test_smooth.sh` | 17 assertion untuk filter tampilan, tanpa HP |
| `_t/t_seed.sh` | Uji clamp `SEED_MIN` |
| `tools/patch_fast.py` | Tukar `battfixd.sh` + pangkas 7 modul debug |
| `tools/fdt_patch.py` | Patch node `mtk_gauge` di DTB |
| `tools/verify_image.py` | Diff struktural stock vs hasil patch |
| `tools/vbimg2.py` | LZ4 legacy + cpio newc parse/build |

### 13.5 Image

| Berkas | Keterangan | sha256 |
|---|---|---|
| `OrangeFox-honest-tanzanite.img` | v1, DTB + battfixd | — |
| `OrangeFox-honest-v2-smooth-tanzanite.img` | v2, filter halus | `4500d008f32f24a39d2f63e6c0d714c9dea84d88f974ed69c83127edae003471` |
| `OrangeFox-honest-v3-noseed0-tanzanite.img` | v3, `SEED_MIN=1` | `13db66d51850e86350ef6bb56f8d5a027df99d82e9c51ec827ff5c3613cb33e9` |

Semua 67.108.864 byte. Repo: `github.com/gbrsaski20/twrp_tanzanite`.

### 13.6 Detail teknis toolchain yang mahal ditemukan

- Ramdisk di boot image `ANDROID!` mulai di **page boundary berikutnya** setelah
  kernel, bukan langsung setelahnya.
- LZ4 wajib level 9. Default menghasilkan 71.6 MB dan meluber dari partisi 64 MB.
- Offset FDT `walk()` bersifat absolut di dalam blob — jangan menambahkan offset
  blob lagi.
- Pemangkasan modul harus dicek terhadap `modules.dep`. Menghapus
  `mmprofile.ko`, `irq-dbg.ko`, `mtk-smi-dbg.ko`, `mtk-mmc-dbg.ko`,
  `clk-chk-mt6789.ko`, `clk-dbg-mt6789.ko` merusak `mediatek-drm.ko` dan
  `mtk-mmc.ko` — artinya tidak ada layar dan tidak ada storage.
- `post_rom_flash.sh` menulis `fox_backup.img` ke `vendor_boot_a` **dan**
  `vendor_boot_b`, jadi image harus di-flash ke dua slot.

---

## 14. Ringkasan satu paragraf

Gauge MT6358 di kernel ini punya bug skala: `ptim_battery_voltage_get`
mengembalikan kode ADC dengan rasio tetap ~0.86 terhadap tegangan sebenarnya,
lalu driver memakainya langsung sebagai tegangan. Karena pembacaan OCV hardware
juga gagal (`_hw_ocv=0`), driver selalu jatuh ke jalur ini dan memulai setiap
boot pada ~82-100%. Satu-satunya yang menyelamatkan angka adalah nilai
`rtc_ui_soc` yang diwariskan dari sesi sebelumnya — tapi driver memperlakukan
nilai 0 sebagai "tidak ada data", sehingga justru saat baterai benar-benar
habis (0%) angka melompat ke 82%. Perbaikan yang sudah terbukti terdiri dari
patch DTB (mematikan latch 100%), daemon OCV di recovery (angka jujur), reset
FG sekali (memutus state korup), dan larangan menyimpan 0 (v3).
