# site/

MacHUD's website and app catalog, published by GitHub Pages at
<https://jamesrisberg.github.io/machud/>.

| File | What it is |
| --- | --- |
| `catalog.json` | The app catalog (schema below). Written by HUDKit's `hud-release.sh` when an app is released; MacHUD reads it for Settings → Apps and `machud apps install`. |
| `index.html` | The one-page site. Static HTML plus a small script that fetches `catalog.json` (relative) at page load and fills in the MacHUD download button and the app grid. |
| `style.css` | Its styles (dark by default, light when the system is). |
| `generate.sh` | Renders `apps.html`, a static list of the catalog for readers without JavaScript. Needs `jq`. |
| `.nojekyll` | Serve files as-is. |

There is no build step. `.github/workflows/pages.yml` runs on every push to `main` that
touches `site/`: it validates `catalog.json`, runs `generate.sh`, and uploads the folder as
the Pages artifact. `apps.html` is therefore never committed (it is in `.gitignore`).

## Preview locally

```sh
site/generate.sh                      # optional: the no-JS page
python3 -m http.server -d site 8000   # then open http://localhost:8000
```

`index.html` needs to be served over http (a `file://` page cannot fetch `catalog.json`).
To try other data, point a copy of the page at a different catalog, or edit
`catalog.json` locally without committing it.

## catalog.json

```json
{"schemaVersion": 1, "updatedAt": "2026-09-27T00:00:00Z", "hudkit": "0.1.0",
 "apps": [{"id": "xyz.machud.sift", "repo": "sift", "name": "Sift",
           "kind": "windowed", "summary": "…", "version": "0.1.0", "minOS": "14.0",
           "download": "https://github.com/…/Sift-0.1.0.zip", "sha256": "…", "size": 2204019,
           "publishedAt": "…", "icon": "https://…/sift.png", "homepage": "…", "bundled": true}]}
```

- `kind`: `windowed`, `hover`, or `umbrella` (MacHUD itself: the site's hero download; the app
  shows a "newer version" note for it but never installs it).
- `download`, `sha256`, `size`: the notarized zip. MacHUD refuses an install whose size or
  SHA-256 differs, or that Gatekeeper (`spctl -a -t install`) rejects.
- `repo`: the GitHub repo name under jamesrisberg (or `owner/name`); with `homepage` it gives
  the release page the site and MacHUD link to.
- `icon`, `download`: absolute URLs, or relative to `catalog.json`.
- `bundled`: installed by "Install bundled tools" and pre-selected on MacHUD's first run.
