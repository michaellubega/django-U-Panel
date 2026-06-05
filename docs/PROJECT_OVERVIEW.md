# U-Panel · KIU — project overview

Visual, single-page narrative for **U-Panel** at **KIU**: who uses the app, what pain it removes, architecture, stack, roles, and roadmap. Styling (colors, typography, diagrams) lives in HTML/CSS and SVG—not duplicated here.

## Files

| File | Purpose |
|------|---------|
| [SYSTEM_REQUIREMENTS.md](./SYSTEM_REQUIREMENTS.md) | Minimum/recommended OS, hardware, browser, network, and permissions for **Windows**, **Android**, **Web**, and **iOS**. |
| [PROJECT_OVERVIEW.html](./PROJECT_OVERVIEW.html) | Full scrollable overview (hero + all sections in one page). |
| [PROJECT_OVERVIEW_PRESENTATION.html](./PROJECT_OVERVIEW_PRESENTATION.html) | Same content and styling, split into slides with keyboard/UI navigation. |
| [_build_presentation.py](./_build_presentation.py) | Regenerates the presentation from the overview HTML. |
| [_build_powerpoint.py](./_build_powerpoint.py) | From **`PROJECT_OVERVIEW.html`**: **[U_Panel_KIU_Overview.pptx](./U_Panel_KIU_Overview.pptx)** (native text + diagrams as **Inkscape EMF** if available, else **Playwright PNG** of each `figure.diagram`) and **[U_Panel_KIU_Overview_screenshots.pptx](./U_Panel_KIU_Overview_screenshots.pptx)** (full-slide PNG deck). **`--native-only`** skips the screenshot deck. **`--screenshot`** only writes the screenshot deck. Close open `.pptx` files before re-running. |
| [requirements-powerpoint.txt](./requirements-powerpoint.txt) | Python deps for the PowerPoint build. |

## Full document (`PROJECT_OVERVIEW.html`)

Open in any browser (double-click or drag into a tab). Includes:

1. **Overview** — U-Panel at KIU; student journey strip; people → app → cloud hub.
2. **Pain** — operational friction clusters (paper, chasing, rework, visibility, offline gaps).
3. **Shift** — QA linear flow; before → after paired rows.
4. **Product** — feature surfaces and attendance lifecycle strip; notice → push pipeline.
5. **Architecture** — client + cloud + automation layered diagram (Flutter vs Firebase).
6. **Stack** — Flutter, Firebase, Functions, device/offline, ship targets.
7. **Roles** — Student vs QA-Staff surfaces.
8. **Value** — three outcome pillars.
9. **Next** — roadmap waves (Now → Later).
10. **Close** — one-line takeaway and footer.

## Presentation (`PROJECT_OVERVIEW_PRESENTATION.html`)

- **Slides**: title (hero only), then one slide per section **1–9**, then a final slide for **10. Close** plus the same footer as the HTML overview.
- **Controls**: **Previous** / **Next** at the bottom; **←** **→**, **Page Up/Down**, **Space** (when not on a button/link); **Home** / **End** for first/last slide.
- **Full document**: top-right link returns to `PROJECT_OVERVIEW.html`.

### Regenerate after editing the overview

From the repo root:

```bash
python docs/_build_presentation.py
```

This re-reads `PROJECT_OVERVIEW.html` and overwrites `PROJECT_OVERVIEW_PRESENTATION.html`. Keep the overview as the source of truth for copy and diagrams.

## PowerPoint

Generated from [PROJECT_OVERVIEW.html](./PROJECT_OVERVIEW.html).

### `U_Panel_KIU_Overview.pptx`

- **Text** (`h1`, `h2`, `p`, lists) → real PowerPoint text (Calibri, colors from `:root`).
- **Diagrams**: **[Inkscape](https://inkscape.org/) → EMF** when `inkscape` is on `PATH`; otherwise **Playwright** saves each **`figure.diagram`** as a **PNG** from Chromium (includes diagram frame styling from the HTML).

### `U_Panel_KIU_Overview_screenshots.pptx`

- Produced by default in the same run: **full-slide PNG** slices (hero, each `<h2>` section, last section + footer), `device_scale_factor=2` for sharper images.

### Commands

```bash
pip install -r docs/requirements-powerpoint.txt
playwright install chromium
python docs/_build_powerpoint.py              # both .pptx files
python docs/_build_powerpoint.py --native-only   # only U_Panel_KIU_Overview.pptx
python docs/_build_powerpoint.py --screenshot    # only U_Panel_KIU_Overview_screenshots.pptx
```

Layout in the native deck is a **simple vertical stack** (not a full CSS engine). Re-run after editing the HTML; close open output files in PowerPoint if you see a permission error.

## Notes

- Diagrams are inline SVG in the HTML; this markdown does not embed them.
- For print/PDF, use the browser print dialog on either file; the presentation stylesheet uses page breaks between slides when printing.
