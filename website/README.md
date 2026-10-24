# OpenMaé website

The site of openmae.com: a few static pages, no build step. The only other origin is the audience measurement
(Umami, a.openmae.com), and only on openmae.com itself.

```
public/
  index.html             home, in French (the default)
  en/index.html          home, in English
  confidentialite/       privacy, in French: what stays on the Mac and what leaves it, feature by feature
  en/privacy/            privacy, in English
  p/index.html           where the Mac's pairing QR code leads (both languages)
  .well-known/apple-app-site-association
                         opens that link in the iPhone app instead, when it is installed (universal link)
  404.html               page not found (both languages)
  assets/                site.css, site.js, analytics.js, the app's fonts and their licenses, the share images
scripts/make-images.py   redraws the share images and the PNG icons (needs Pillow)
nginx.conf, Dockerfile   to serve it
```

## Design

The site follows the app's design system. Colors, radii, shadows, durations and curves are the app's design tokens,
and the typefaces are the app's own files (Bricolage Grotesque and Figtree, SIL Open Font License 1.1). The demos (the
Mac window, the capsule, the iPhone) are drawn in HTML and CSS after the app's orb, live transcript and capsule;
`site.js` plays them with the timing and the conversation of the app's demo mode, and the colors follow the
conversation's state as they do in the app. No purple, no gradient. Every animation stops with the system's reduced
motion setting or the page's pause button.

## Texts

The French pages say *tu*, with a non-breaking space before `:` `;` `!` `?`, inside « », and between a number and its
unit, as in the app. A page never states a number the app has not measured. Change both languages together, and the
privacy pages whenever a feature changes what leaves the Mac.

## Audience measurement

Every page but `/p` loads `assets/analytics.js`, which adds Umami's script (`https://a.openmae.com/script.js`, with the
website id) only when the page is served from openmae.com: in development (localhost, a local address, the container
on your own Mac) nothing is loaded and nothing is sent. Umami sets no cookie. `nginx.conf` allows a.openmae.com in the
Content-Security-Policy, except on `/p`. The privacy pages say what Umami records: change them with its settings.

## Preview

```bash
python3 -m http.server 4173 --directory website/public
```

Then open http://localhost:4173. Python's server redirects `/p` to `/p/` and has its own "not found" page; nginx does
neither.

## The pairing page

The Mac's QR code is a link, `https://openmae.com/p#v=1&id=…&pk=…&code=…&name=…`
(`Sources/OpenMaeLink/PairingLink.swift`). The OpenMaé app reads it with its own scanner, and the iPhone's Camera opens
it in the app too, as a universal link: the app declares the associated domain `applinks:openmae.com`
(`iPhone/project.yml`), and `public/.well-known/apple-app-site-association` names the app for `/p` (its Apple team id and
bundle id, which this file makes public). Without the app, the Camera opens the link in the browser, on `p/index.html`.
Everything after `#` stays in the browser: keep that page free of anything loaded from elsewhere (it does not load
`analytics.js`, and its Content-Security-Policy allows no other origin), and never read `location.hash` there.

An iPhone does not fetch `apple-app-site-association` from the site: Apple's CDN does, and keeps it for a while. The
file must answer over HTTPS as JSON (`nginx.conf` sets `application/json`, as the file has no extension), without a
redirect, and a firewall or a CDN in front of the site must let Apple's fetcher through. After a change to that file,
check what Apple's CDN serves, `https://app-site-association.cdn-apple.com/a/v1/openmae.com`: an iPhone reads it there
when the app is installed or updated.

## Deploying

```bash
docker build -t openmae-website website
```

```bash
docker run --rm -p 8080:8080 openmae-website
```

Put it behind a reverse proxy that terminates TLS for openmae.com. `nginx.conf` sends a strict
Content-Security-Policy (no inline script or style, no other origin but a.openmae.com, none at all on `/p`): keep the
pages that way. Pages, styles and scripts go out with `Cache-Control: no-cache`, since their names carry no version:
browsers and a CDN check them again at each visit, so a deployment shows at once. Only the fonts are cached for a year.
