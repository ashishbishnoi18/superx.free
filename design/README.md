# Design reference

Static mockups of four screens in the editorial system, ported from
upboost (`kit:/var/www/upboost/assets/css/app.css`).

**The app is canonical.** This directory shadows it — the real tokens and
components live in `assets/css/app.css` and `lib/superx_web/`. Keep this
for sketching a screen without booting Phoenix, but when the two disagree,
the app wins.

```bash
cd design && python3 -m http.server 4173 --bind 127.0.0.1
```

`index.html` (Ready to Post) · `queue.html` · `inspiration.html` ·
`analytics.html`. Theme toggle top right; it persists.

Fonts here are copies of upboost's, self-hosted so the prototype runs
offline. The app serves the same files from `priv/static/fonts/`.
