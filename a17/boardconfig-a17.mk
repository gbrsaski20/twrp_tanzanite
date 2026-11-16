# =============================================================================
# Flag kripto recovery untuk ROM Android 17 (Halcyon 17.0, SDK 37)
#
# Di-append ke device/xiaomi/tanzanite/BoardConfig.mk oleh workflow
# (.github/workflows/build.yml, langkah "A17 crypto overlay") atau oleh
# build_twrp_tanzanite.sh saat build lokal.
#
# Dasar: fstab.mt6789 dari vendor_boot Halcyon A17
#   fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized
#   keydirectory=/metadata/vold/metadata_encryption
#   fsverity, inlinecrypt, checkpoint=fs
# =============================================================================

TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true

# Metadata encryption (/metadata/vold/metadata_encryption) wajib dibaca
# sebelum /data bisa di-mount. Tanpa flag ini TWRP berhenti di
# "Unable to decrypt" walau keymaster/keymint sehat.
TW_INCLUDE_FBE_METADATA_DECRYPT := true

# FBE policy v2 - sama dengan versi di fstab ROM A17.
TW_USE_FSCRYPT_POLICY := 2

# Paksa jalur keymaster/keymint versi perangkat, jangan fallback ke
# software keymaster (libsoftkeymasterdevice tidak bisa membuka key blob TEE).
TW_FORCE_KEYMASTER_VER := true

# Modul kernel (termasuk mitee.ko/tee.ko untuk TEE MTK) diambil dari
# lib/modules di ramdisk, yang harus berasal dari build kernel ROM A17.
TW_LOAD_VENDOR_BOOT_MODULES := true
