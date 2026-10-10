# Settings assets

- `Fonts/NotoSansSC.ttf`: Noto Sans SC variable font from
  https://github.com/google/fonts/tree/main/ofl/notosanssc (SIL OFL, included).
- `Lucide/*.svg`: original Lucide icons from
  https://github.com/lucide-icons/lucide/tree/main/icons (ISC/MIT, included).
- `Lucide/*.pdf`: vector copies of the SVGs for AppKit template rendering;
  24 × 24 view box, 2-unit stroke, round joins and caps. No bitmap scaling.

Downloaded 2026-10-08. Fonts register only within the app process; no system
font installation is required. See `native/tools/prepare-settings-icons.py`
to regenerate PDFs with ReportLab.
