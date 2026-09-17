# AntiRKN app icon

Hand-edited vector based on the SVG supplied by the owner on 2026-09-17. Server stack, globe, orbit and shield are retained; tracing noise and redundant points are removed. `app_icon.svg` is the color master; `app_icon_monochrome.svg` has real transparent cutouts for Android theme tinting. Neither contains embedded bitmaps or external links.

Run `python3 tool/generate_app_icons.py` from the repository root (librsvg and Pillow required). It exports Android VectorDrawable/adaptive/monochrome and legacy PNG resources, Windows ICO (16–256px), and Linux PNG. Exported application resources are tracked; build outputs are not.

Android artwork is inside a centered 33dp-radius safe circle in a 108dp canvas. Android 13+ uses the monochrome layer when themed icons are enabled and supported by the launcher. See [Android adaptive icons](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive). On Android 12+ the normal adaptive icon also resolves all four colors from system accent resources, including light/dark variants, so App info and other hosts do not need monochrome support. Android 11 and older, SVG exports and desktop assets use the fixed teal/blue fallback. See [AOSP dynamic color](https://source.android.com/docs/core/display/material).
