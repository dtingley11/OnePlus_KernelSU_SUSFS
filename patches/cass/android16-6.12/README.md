# CASS for android16-6.12.38 (OnePlus Ace 6T, SM8845)

Capacity Aware Superset Scheduler (CASS) by Sultan Alsawaf, ported to the
pinned OnePlus `wild/sm8845` tree:

- Kernel source: `OnePlusOSS/android_kernel_common_oneplus_sm8845` at
  `c1102892bf2eb5806e135f5169b3dcfd72f96c47` (android16-6.12-2025-09_r17,
  Makefile version 6.12.38).
- CASS source: Sultan Alsawaf's `16.0.0-sultan` branch, tip `201c5c7c99f8`,
  i.e. the CASS core plus all of its follow-up fixes.

The build action applies the patches in order after the kernel source is
synced and before the build starts, in the step `Apply CASS Patches` of
`.github/actions/build-kernel/action.yml`. The step is enabled when the device
config sets `"cass": true`, and it aborts the build if any patch fails to
apply. `CONFIG_SCHED_CASS=y` is appended to `arch/arm64/configs/gki_defconfig`
by the same step; the option itself is defined in `init/Kconfig` by patch 0002.
A later step, `Verify CASS in Final Config`, checks that the generated
`out/.config` contains `CONFIG_SCHED_CASS=y` and that the built kernel's
`System.map` contains the CASS runqueue-selection symbols.

Manual equivalent:

```bash
cd "$COMMON_KERNEL_FOLDER"
for p in patches/cass/android16-6.12/0*.patch; do
  patch -p1 --forward < "$p"
done
echo "CONFIG_SCHED_CASS=y" >> arch/arm64/configs/gki_defconfig
```

## What is ported

- `arch_scale_min_freq_capacity()` / `arch_set_min_freq_scale()` (patch 0001),
  the prerequisite CASS needs to reason about uclamp-boosted tasks.
- `kernel/sched/cass.c` and `kernel/sched/cass_rt.h` (patch 0002), which
  replace `select_task_rq_fair()` and `select_task_rq_rt()`.
- Skipping `update_idle_cpu_scan()` (patch 0003), whose result CASS never
  uses.

The only deviations from upstream CASS are the 6.12 API changes: `util_est`
is a plain unsigned int since 6.8, and the thermal PELT accessors are named
`hw_*` in 6.12. No SoC-specific tuning (energy-model pricing, cluster rules,
runtime module parameters) is carried over from other 6.12 CASS ports.

## Vendor hooks

`select_task_rq_fair()` and `select_task_rq_rt()` in this tree call
`android_rvh_select_task_rq_fair()` / `android_rvh_select_task_rq_rt()`.
Those calls are not reached when CASS is enabled. No in-tree code registers
those hooks (`grep -rn android_rvh_select_task_rq` only finds the hook
definitions and their `EXPORT_TRACEPOINT_SYMBOL_GPL()` lines), so no
bundled vendor module loses functionality. If a future build adds a vendor
scheduler module that uses them, CASS must be disabled for that device.
