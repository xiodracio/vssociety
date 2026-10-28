# VARONIS

Static site for **VARONIS — India’s First Secret Society**. Plain HTML/CSS/JS, no build step.

## Structure

```
index.html            main page (3D membership card via three.js r128)
404.html              not-found page
assets/               logo mark, wordmark, card front/back textures
favicon-32.png        favicon
apple-touch-icon.png  home-screen icon
robots.txt
.nojekyll             tells GitHub Pages to serve files as-is
```

## Deploy on GitHub Pages

1. Create a repo and upload everything in this folder to the repo root (keep `.nojekyll`).
2. Go to **Settings → Pages**.
3. Under **Build and deployment**, choose **Deploy from a branch**, pick `main` and `/ (root)`, then Save.
4. The site goes live at `https://<username>.github.io/<repo>/` within a minute or two.

Custom domain: add it under Settings → Pages, and add a file named `CNAME` containing the domain.

## Run locally

Open it through a local server, not by double-clicking the file. Browsers block WebGL textures loaded from `file://`, so the 3D card would fall back to a flat image.

```
python3 -m http.server 8000
```

Then visit http://localhost:8000.

## Notes

- The 3D card and fonts load from CDNs (cdnjs, Google Fonts), so visitors need an internet connection.
- For rich link previews, add `og:image` and `og:url` meta tags with absolute URLs once the final address is known.
