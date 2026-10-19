#!/usr/bin/env bash
# SM8845 profile helpers. No downloaded setup scripts are executed.
set -euo pipefail
profile_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
profile_lock="$profile_root/.github/sm8845-lock.json"
ksu_sha=$(jq -er '.ksu.commit' "$profile_lock")
susfs_sha=$(jq -er '.susfs.commit' "$profile_lock")
fail() { echo "::error::$*" >&2; exit 1; }

case "${1:-}" in
  install-ksu)
    [[ "$OP_SOC/$OP_ANDROID_VERSION/$OP_KERNEL_VERSION" = canoe/android16/6.12 ]] || fail 'Incorrect SM8845 kernel family'
    [[ ! -e "$KSUN_FOLDER" && ! -e "$COMMON_KERNEL_FOLDER/drivers/kernelsu" ]] || fail 'KernelSU already present; start with a fresh source tree'
    git clone --no-checkout https://github.com/KernelSU-Next/KernelSU-Next.git "$KSUN_FOLDER"
    git -C "$KSUN_FOLDER" checkout --detach "$ksu_sha"
    [[ $(git -C "$KSUN_FOLDER" rev-parse HEAD) = "$ksu_sha" ]] || fail 'KernelSU revision mismatch'
    [[ $(git -C "$KSUN_FOLDER" rev-list --count HEAD) = 3239 ]] || fail 'Unexpected KernelSU history/version'
    # Same wiring as the inspected upstream setup.sh, without its fallback checkout.
    ln -s ../../KernelSU-Next/kernel "$COMMON_KERNEL_FOLDER/drivers/kernelsu"
    grep -q 'kernelsu' "$COMMON_KERNEL_FOLDER/drivers/Makefile" && fail 'Duplicate KernelSU Makefile entry'
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$COMMON_KERNEL_FOLDER/drivers/Makefile"
    grep -q 'drivers/kernelsu/Kconfig' "$COMMON_KERNEL_FOLDER/drivers/Kconfig" && fail 'Duplicate KernelSU Kconfig entry'
    printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$COMMON_KERNEL_FOLDER/drivers/Kconfig"
    ;;
  apply-susfs)
    [[ "$KSU_COMMIT_SHA" = "$ksu_sha" && "$SUSFS_COMMIT_SHA" = "$susfs_sha" ]] || fail 'Unreviewed KernelSU/SUSFS revision pair'
    [[ "$KERNEL_FULL_VER" = android16-6.12.38 ]] || fail 'SUSFS adaptation is reviewed only for Android 16 / Linux 6.12.38'
    [[ ! -e "$COMMON_KERNEL_FOLDER/.sm8845-susfs-applied" && ! -e "$COMMON_KERNEL_FOLDER/fs/susfs.c" ]] || fail 'SUSFS already present; refusing duplicate application'
    grep -qx '#define SUSFS_VERSION "v2.2.0"' "$SUSFS_FOLDER/kernel_patches/include/linux/susfs.h" || fail 'Unexpected SUSFS version'
    printf '%s  %s\n' "$(jq -r '.susfs.kernel_patch_sha256' "$profile_lock")" "$SUSFS_FOLDER/kernel_patches/50_add_susfs_in_gki-android16-6.12.patch" | sha256sum -c -
    printf '%s  %s\n' "$(jq -r '.compatibility_patches.adapted_patch_sha256' "$profile_lock")" "$profile_root/patches/sm8845/ksun-susfs.patch" | sha256sum -c -
    common_patch=$(mktemp)
    trap 'rm -f "$common_patch"' EXIT
    # OnePlus 6.12.38 lacks the Android memfd_class comment below selinux_state.
    # Change only the context of this hunk; all added SELinux code is retained.
    python3 - "$SUSFS_FOLDER" "$common_patch" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]) / 'kernel_patches/50_add_susfs_in_gki-android16-6.12.patch'
s = source.read_text()
old = ' /*\n  * ANDROID: selinux_state is part of the KMI, and adding memfd_class as part of the policycap\n'
new = ' /* SECMARK reference count */\n static atomic_t selinux_secmark_refcount = ATOMIC_INIT(0);\n'
if s.count(old) != 1:
    raise SystemExit('Unexpected SUSFS SELinux patch context; review the pinned patch')
Path(sys.argv[2]).write_text(s.replace(old, new))
PY
    # Check both complete patches before mutating either tree. No rejects or fuzz.
    for mode in check apply; do
      patch_args=(--batch --forward --fuzz=0 --no-backup-if-mismatch -p1)
      [[ "$mode" != check ]] || patch_args+=(--dry-run)
      patch "${patch_args[@]}" -d "$KSUN_FOLDER" -i "$profile_root/patches/sm8845/ksun-susfs.patch" || fail "KernelSU SUSFS patch failed ($mode)"
      patch "${patch_args[@]}" -d "$COMMON_KERNEL_FOLDER" -i "$common_patch" || fail "Android 16 / 6.12 SUSFS patch failed ($mode)"
    done
    cp "$SUSFS_FOLDER"/kernel_patches/fs/* "$COMMON_KERNEL_FOLDER/fs/"
    cp "$SUSFS_FOLDER"/kernel_patches/include/linux/* "$COMMON_KERNEL_FOLDER/include/linux/"
    # SUSFS owns the inline hooks; do not add the legacy manual hooks again.
    printf '\nCONFIG_KSU_SUSFS=y\n' >> "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig"
    touch "$COMMON_KERNEL_FOLDER/.sm8845-susfs-applied"
    printf 'SUSVER=v2.2.0\nNEED_HOOKS=false\nCONFIG_FAKE_DISABLE=\n' >> "$GITHUB_ENV"
    printf 'v2.2.0\n' >> "$ARTIFACTS_FOLDER/${OP_MODEL}_${OP_OS_VERSION}.txt"
    ;;
  package-metadata)
    # The package replaces only Image inside the existing boot image. No modules,
    # DTB, DTBO, vendor_boot, init_boot, or firmware partitions are supplied.
    cp "$CONFIG_FOLDER/manifest.xml" "$AK3_FOLDER/manifest.xml"
    cp "$COMMON_KERNEL_FOLDER/out/.config" "$AK3_FOLDER/kernel.config"
    python3 - "$profile_lock" <<'PY'
import json, os
from pathlib import Path
e = os.environ
info = json.loads(Path(__import__('sys').argv[1]).read_text())
info.update(device=e['OP_MODEL'], build_commit=e['GITHUB_SHA'],
            run_url=f"https://github.com/{e['GITHUB_REPOSITORY']}/actions/runs/{e['GITHUB_RUN_ID']}",
            compiler=e['CLANG_VERSION'], kernel_release=e['KERNEL_UNAME'],
            vendor_modules='retained from installed firmware; not rebuilt',
            device_trees='retained from installed firmware; not replaced')
Path(e['AK3_FOLDER'], 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')
PY
    for required in Image anykernel.sh tools/ak3-core.sh tools/magiskboot META-INF/com/google/android/update-binary; do
      [[ -s "$AK3_FOLDER/$required" ]] || fail "Incomplete AnyKernel3 package: $required"
    done
    # Avoid silently packaging a DTB/module payload from a future template change.
    [[ ! -d "$AK3_FOLDER/modules" && ! -e "$AK3_FOLDER/dtb" && ! -e "$AK3_FOLDER/dtbo.img" ]] || fail 'Unexpected module/device-tree payload in GKI package'
    ;;
  *) fail 'Usage: sm8845.sh {install-ksu|apply-susfs|package-metadata}' ;;
esac
