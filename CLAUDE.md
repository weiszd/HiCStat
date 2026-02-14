# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

HiCStat is a zero-dependency, single-page web app that inspects `.hic` file headers (Hi-C genomic contact matrices) by reading only the first 256 KB via HTTP Range requests. It accepts ENCODE accessions (`ENCFF...`) or direct URLs, parses the binary header, and displays metadata (version, genome, chromosomes, resolutions, attributes/statistics).

**Live site:** https://weiszd.github.io/HiCStat/

## Deployment

Push to `master` triggers GitHub Actions (`.github/workflows/pages.yml`) which deploys the repo root to GitHub Pages. There is no build step — `index.html` is served directly.

Git config for this repo: user `weiszd`, email `weiszd@users.noreply.github.com`.

## Architecture

Everything lives in `index.html` — CSS, HTML, and all JavaScript in a single file. No frameworks, no bundler, no npm.

### Key code sections (all in `index.html <script>`):

- **BinaryParser** — DataView wrapper for reading little-endian binary types (int, long as BigInt, null-terminated strings) from an ArrayBuffer
- **parseHicHeader()** — Parses the .hic binary format: magic "HIC", version (v5–v9+), footer position, genome ID, normalization vector index (v9+), key-value attributes, chromosome list, BP resolutions, fragment resolutions
- **resolveUrl() / resolveEncodeAccession()** — Input routing: detects URLs vs ENCODE accessions (`ENCFF` prefix), fetches ENCODE JSON API at `encodeproject.org/files/{accession}/?format=json`
- **S3 Proxy routing** — `needsProxy()` checks if URL hostname is in `PROXIED_S3_HOSTS`; if so, routes through the Supabase Edge Function proxy instead of direct fetch
- **fetchHeaderBytes()** — Fetches first 256 KB via Range request (direct or proxied), with sanity check for HTML-instead-of-binary responses
- **renderResults()** — Builds card-based HTML for ENCODE metadata, header info, resolutions, chromosomes table, and expandable attributes (statistics auto-expands)
- **autoLoad()** — On page load, checks URL path or `?q=` param for deep linking (e.g., `/HiCStat/ENCFF090JFB`)

### S3 Proxy (Supabase Edge Function)

`hicfiles.s3.amazonaws.com` requires `Referer` matching an allowlist (aidenlab.org, igv.org, etc.) or `User-Agent` matching `straw*`/`IGV*`. Browsers can't set these headers cross-origin, so a Supabase Edge Function at `pjrwcsbzsabikiezwter.supabase.co/functions/v1/hic-proxy` proxies the request, adding the required headers server-side.

- Supabase project ID: `pjrwcsbzsabikiezwter`
- Function slug: `hic-proxy`
- JWT verification is disabled (public access)
- Allowed hosts: `hicfiles.s3.amazonaws.com`, `4dn-open-data-public.s3.amazonaws.com`, `encode-public.s3.amazonaws.com`

### SPA Routing

`404.html` handles GitHub Pages SPA routing — redirects `/HiCStat/ENCFF090JFB` to `/HiCStat/?q=ENCFF090JFB`, which `autoLoad()` picks up.

## .hic Binary Format Reference

Spec: https://github.com/aidenlab/hic-format

Header layout (little-endian): magic string "HIC" (null-terminated) → int32 version → int64 footer position → string genome ID → [v9+: int64 nvi position, int64 nvi length] → int32 nAttributes → (string key, string value) × n → int32 nChromosomes → (string name, int32/int64 size) × n → int32 nBpResolutions → int32[] → int32 nFragResolutions → int32[]

Chromosome sizes are int32 in v5–v8, int64 (BigInt) in v9+.

## ENCODE API Gotchas

- `assay_term_name` can be a string or an array — always handle both
- `biosample_ontology` can be an object or array of objects
- `lab` can be a string or an object with `.title`
- `href` is a relative path (no domain) — prepend `https://www.encodeproject.org`
- ENCODE download URLs 307-redirect to presigned S3 URLs; `fetch` with `redirect: 'follow'` handles this with CORS
