# RasterNest brand

**Tagline:** Capture. Refine. Share.

## Logo

The mark combines three ideas:

| Part | Meaning |
|---|---|
| 3×3 pixel grid (violet → sky) | **Raster**: the image itself |
| Layered swoosh under the grid | **Nest**: a home that keeps captures organised |
| Viewfinder brackets | **Capture**: framing the screen |

Every asset comes from one drawing in `scripts/generate-brand.swift`:

```sh
swift scripts/generate-brand.swift
```

It writes the app icon (`Resources/AppIcon.icns`), website icons and social image (`site/assets/`), the vector mark (`site/assets/logo-mark.svg`), and the README banners (`docs/assets/`). Change the geometry or colors there and re-run it; don't edit the generated files by hand.

**Variants**
- On dark surfaces: white brackets and a white→lavender front ribbon (app icon, website header).
- On light surfaces: ink brackets and a lavender→sky front ribbon (`banner-light.png`). In the SVG, set `color` for the brackets and `--rn-front-from` / `--rn-front-to` for the front ribbon.
- Menu bar: a single-color template version, drawn in `Brand.menuBarImage()`.

Keep clear space around the mark of at least the width of one grid cell. Don't recolor the grid, add effects, or set the wordmark in another typeface.

## Color

| Token | Hex | Use |
|---|---|---|
| Primary | `#7C3AED` | Buttons, selected tools, selection handles, links |
| Accent | `#0EA5E9` | Secondary highlights, callouts, info |
| Highlight | `#38BDF8` | Window hover in the capture overlay, gradients |
| Surface | `#0B1020` | Dark backgrounds, app icon, footer |
| Subtle | `#334155` | Secondary text on light |
| Border | `#E2E8F0` | Dividers and outlines on light |
| Background | `#F8FAFC` | Light page background |

Brand gradient: `#7C3AED → #38BDF8` (left to right), used in the grid and the website tagline.

## Typography

- **SF Pro** (system font): the app, the wordmark, and generated images.
- **Inter**: the website, docs and GitHub. JetBrains Mono for code.
- Wordmark: "RasterNest", one word, capital R and N, bold, slightly tight tracking.
