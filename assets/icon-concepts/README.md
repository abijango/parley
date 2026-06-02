# Parley — app icon concepts

<!-- TODO(app-name): named for the "Parley" direction. -->
Three editable SVG concepts, all built on the macOS squircle grid (1024×1024,
corner radius 228 ≈ Apple's continuous-corner tile). Open in a browser to view.

| File | Concept | Vibe |
|------|---------|------|
| `parley-bubbles.svg` | **Two speech bubbles meeting** — blue (Me) + green (Remote), overlapping, matching the app's transcript speaker colours. | Clean, literal, on-brand. The safe, scales-tiny pick. |
| `parley-parrot.svg` | **A parrot** — pirate "parley" = a talk/truce, and a parrot is the original talker. Little speech bubble = it's transcribing. | The whimsical one. Most memorable; needs the most refinement. |
| `parley-waves.svg` | **Two tracks converging** — mirrored waveforms growing into a glowing centre node. | Sleek, technical, Obsidian-dark. |

## View them
```bash
open -a Safari assets/icon-concepts/parley-bubbles.svg     # browsers render SVG cleanly
qlmanage -t -s 1024 -o /tmp assets/icon-concepts/parley-parrot.svg   # → /tmp/*.png thumbnail
```

## Turn a chosen SVG into a macOS .icns
1. Rasterise to PNGs (needs `librsvg`: `brew install librsvg`):
   ```bash
   SVG=assets/icon-concepts/parley-bubbles.svg
   mkdir Parley.iconset
   for s in 16 32 64 128 256 512 1024; do
     rsvg-convert -w $s -h $s "$SVG" -o "Parley.iconset/icon_${s}x${s}.png"
   done
   # Retina @2x variants:
   for s in 16 32 128 256 512; do
     rsvg-convert -w $((s*2)) -h $((s*2)) "$SVG" -o "Parley.iconset/icon_${s}x${s}@2x.png"
   done
   iconutil -c icns Parley.iconset -o Parley.icns
   ```
2. Or use Apple's **Icon Composer** (Xcode 26) — import the 1024 PNG, it generates
   the full set incl. the Liquid Glass / dark / tinted variants for macOS 26.

## Notes
- Colours intentionally reuse the in-app palette: Me = blue `#2C7BF2`, Remote = green `#1FB457`.
- These are starting points — the bubbles & waves are production-clean; the parrot's
  curves should be smoothed in a vector editor before shipping.
