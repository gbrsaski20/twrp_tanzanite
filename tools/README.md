# tools/

Perkakas Python yang dipakai untuk membongkar dan membangun ulang
`vendor_boot.img` tanzanite. Tidak ada dependensi selain `lz4`:

```sh
pip install lz4
```

## Alur build

```sh
# 1. ganti daemon + pangkas modul debug
python tools/patch_fast.py vendor_boot_stock.img vendor_boot_battfix.img

# 2. patch node mtk_gauge di DTB (matikan latch 100%)
python tools/fdt_patch.py vendor_boot_battfix.img vendor_boot_honest.img \
    --pseudo100 100 --keep100 0

# 3. cek hasilnya
python tools/verify_image.py vendor_boot_stock.img vendor_boot_honest.img
```

`verify_image.py` harus melaporkan tepat **dua** entri berubah
(`system/bin/battfixd.sh` dan `lib/modules/modules.load.recovery`) dan frag0
byte-identik. Kalau lebih dari itu, ada yang salah.

## Isi

| File | Fungsi |
|---|---|
| `vbimg2.py` | parser/builder `vendor_boot` (header v4, multi-fragmen), LZ4 legacy frame, cpio `newc` |
| `vbimg.py` | versi awal parser, dipakai `extract_frags.py` |
| `patch_fast.py` | build utama: ganti `battfixd.sh` + pangkas 7 modul debug |
| `patch_image.py` | versi minimal: ganti `battfixd.sh` saja, tanpa pangkas modul |
| `fdt_patch.py` | patch properti `mtk_gauge` di DTB secara in-place |
| `fdt_dump.py` | parser FDT minimal, bisa diimpor (`node_props`) |
| `verify_image.py` | diff struktural antara image asli dan hasil patch |
| `extract_frags.py` | tulis tiap fragmen ramdisk ke `work/fragN_*.bin` |
| `bootram.py` | buka ramdisk dari boot image `ANDROID!` biasa |
| `bootimg_info.py` | tampilkan header boot/vendor_boot |
| `unpack_any.py` | deteksi jenis image lalu bongkar otomatis |
| `unpack_ramdisk.py` | bongkar cpio (LZ4 atau gzip) |
| `extract_files.py` | ambil file tertentu dari ramdisk |
| `kerncmp.py` | bandingkan string baterai antara dua kernel |
| `analyze_logcat.py`, `analyze_logcat2.py` | ringkas logcat/dmesg jadi timeline boot |

## Catatan teknis yang mahal kalau lupa

**Ramdisk ada di page boundary berikutnya, bukan tepat setelah kernel.** Di
boot image `ANDROID!`:

```python
off = 4096 + info["kernel_size"]
off = (off + 4095) // 4096 * 4096      # <- ini yang sering terlewat
```

Tanpa pembulatan ini, `bootram.py` membaca nol.

**LZ4 harus level 9.** Kompresi default menghasilkan 71.6 MB dan melewati
partisi 64 MB. `lz4_legacy_compress(data, level=9)` menghasilkan 63.5 MB.

**Offset FDT bersifat absolut.** `walk()` di `fdt_dump.py` mengembalikan offset
terhadap awal blob, bukan terhadap awal image. `fdt_patch.py` pernah menambahkan
offset blob untuk kedua kalinya dan hampir merusak byte yang salah.

**Jangan pangkas modul sembarangan.** Cek `lib/modules/modules.dep` dulu.
Membuang `mmprofile.ko`, `irq-dbg.ko`, `mtk-smi-dbg.ko`, `mtk-mmc-dbg.ko`,
`clk-chk-mt6789.ko` atau `clk-dbg-mt6789.ko` akan mematikan display dan storage
karena modul lain bergantung padanya.
