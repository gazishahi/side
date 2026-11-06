# What Liquid Glass costs Side

Status: reference — measurements (2026-11-06) behind Settings › Appearance › Surfaces; battery figures still to take.

**Result: Liquid Glass costs GPU time while content moves under it, and nothing measurable at rest.** Scrolling the editor, the whole system's GPU was busy 31–32% of the time with glass, against 16–19% with solid surfaces. Idle, the three modes were within noise of each other. Side's own CPU was the same in every mode. So Settings offers Liquid Glass (the default) and Solid; the older blurred material (the pre-macOS 26 fallback) came out between them and isn't offered.

## How it was measured

`scripts/perf/measure-surfaces.sh` runs the UI-test build once per surface mode (`SIDE_SURFACES=glass|vibrancy|solid`) through three scenes, sampling once a second:

- **Idle:** the Editor on a long Swift file, nothing moving.
- **Scrolling:** the Editor scrolling a page a frame, continuously.
- **Terminal:** the Terminal printing a listing every 30 ms, under the stage bar.

It reads, without admin rights:

- **GPU:** `ioreg`'s "Device Utilization %" for the GPU. This is the whole system's, so other apps count too; the baseline is taken with the test build closed.
- **WindowServer CPU:** where much of the compositing happens.
- **Side's CPU** and its Energy Impact, from `top`.
- **Watts:** the Mac's draw from its battery (current × voltage). Only on battery power.

The run: an M3 Pro MacBook Pro (Mac15,6) on AC power, macOS 27.2, two rounds of 15 seconds per scene, with the owner's own Side and other apps open.

## Results

Whole-system GPU use, average %, round 1 / round 2:

| Scene | Liquid Glass | Older blur | Solid |
|---|---|---|---|
| Idle | 7.3 / 5.8 | 5.2 / 5.3 | 6.9 / 6.4 |
| Scrolling | **32.3 / 31.0** | 21.4 / 21.0 | **19.3 / 15.7** |
| Terminal | 5.8 / 3.3 | 1.7 / 1.7 | 5.2 / 1.2 |

Baseline with the test build closed: 14.5 / 4.2. That spread is the noise from everything else running.

- **Scrolling** is the clear signal: glass took about 1.7–2× the GPU time of solid, in both rounds.
- **Idle:** no difference beyond noise.
- **Terminal:** too noisy to call. Its averages are low and swing between rounds; its peaks (glass 34–35, blur 25, solid 18–21) lean the same way as scrolling.
- **Side's CPU:** about 0.2% idle, 12% scrolling, 4.5% in the terminal, whatever the mode.
- **WindowServer's CPU:** 40–50% throughout, mostly the other apps' windows; it showed nothing either way.

What this doesn't say: GPU utilization is time busy, not power. A GPU busy at a low clock can draw little. Watts on battery are the measure that settles it.

## Still to do: battery

On AC power the battery passes no current, so the watts column reads 0. To measure:

1. Charge the Mac, then unplug it.
2. Close what you can, and leave brightness and the keyboard backlight where they are for the whole run.
3. `scripts/uitest/uitest.sh build && scripts/perf/measure-surfaces.sh 120 2`, about 40 minutes.

The battery's gauge updates slowly, so scenes of two minutes or more are needed. Each scene's watts minus the baseline's is what Side costs in it.
