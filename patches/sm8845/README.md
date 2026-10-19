# SM8845 KernelSU-Next / SUSFS adaptation

`ksun-susfs.patch` is a GPL-2.0-only derivative of the KernelSU/SUSFS changes
below, with their original authorship retained. See [LICENSE](LICENSE).
This is a compatibility patch, not a vendored kernel source tree.

Sources:

- [KernelSU-Next 234f6e040fcbca18b16d2398e1aa225712ec99ad](https://github.com/KernelSU-Next/KernelSU-Next/tree/234f6e040fcbca18b16d2398e1aa225712ec99ad), version 33239.
- [simonpunk SUSFS f37930f374ef88de990d6abea0c67d0ea28c1edc](https://gitlab.com/simonpunk/susfs4ksu/-/tree/f37930f374ef88de990d6abea0c67d0ea28c1edc), v2.2.0, `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`.
- [WildKernels compatibility fixes fa76c90e2cb284e6ce22b0b008ad4dd19820dbb1](https://github.com/WildKernels/kernel_patches/tree/fa76c90e2cb284e6ce22b0b008ad4dd19820dbb1/next/susfs_fix_patches/v2.2.0).

The patch consolidates the existing WildKernels integration for this exact pair:

1. The 6.12 Kbuild include/uapi and absolute source-path fixes.
2. SUSFS's KernelSU patch. Its expected conflicts are in Kbuild, core/init.c,
   feature/kernel_umount.c, feature/sucompat.c, hook/setuid_hook.c, and
   supercall/supercall.c.
3. WildKernels' `fix_Kbuild.patch`, `fix_init.c.patch`, `fix_kernel_umount.c.patch`,
   `fix_sucompat.c.patch`, `fix_setuid_hook.c.patch`, `fix_supercall.c.patch`, and
   `overwrite_hook_mode.patch`.

The resulting diff was generated against pristine pinned KernelSU-Next sources
and checked as a complete patch. Production builds never apply a patch partly,
ignore a rejection, or discover fixes from a moving branch. The optional
`ksu_toolkit.patch` is omitted. The patch checksum is recorded in
[the source lock](../../.github/sm8845-lock.json).

The common-kernel patch is still downloaded from simonpunk's pinned commit.
The helper adjusts only one SELinux hunk's context to match OnePlus 6.12.38;
it retains all added code. Both complete patches must pass a dry run with
`--batch --forward --fuzz=0` before either is applied. Line-number offsets are
allowed; missing context is not. Duplicate application aborts the build.

For an update, review the new sources and fixes, regenerate the complete patch
against the new pristine KernelSU revision, update the lock/checksums, and repeat
patch, configuration, compilation, module ABI, and device boot validation.
Do not update just one revision or replace a pin with a branch name.
