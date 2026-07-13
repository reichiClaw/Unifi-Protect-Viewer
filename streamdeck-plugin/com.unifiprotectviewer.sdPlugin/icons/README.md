# Plugin icons

These PNGs are committed so the plugin is self-contained and packageable. They
are generated from `streamdeck-plugin/generate-icons.py` (Pillow):

```bash
pip install pillow
python3 streamdeck-plugin/generate-icons.py
```

Per action there are two assets:

- `‹action›.png` / `@2x` (20×20 / 40×40) — the monochrome **action list** icon.
- `‹action›Key.png` / `@2x` (72×72 / 144×144) — the **key image** drawn on the
  Stream Deck button (glyph + short label).

Plus `plugin`/`category` badges (28×28 / 56×56) and a generic `key` fallback.

This file itself is excluded from the packaged plugin via `.sdignore`.
