# nginx track-file streaming — design

**Date:** 2026-07-31
**Status:** approved, pending implementation plan

## Problem

`nginx/nginx.conf` currently serves exactly one file type: `.hic`. A single regex
location (`location ~* \.hic$`) carries the CORS and Range header block, and
`location /` returns 403 for everything else. Juicebox and IGV load far more than
contact matrices — signal tracks, feature annotations, variant files, 2D loop
lists — and none of them can be streamed from this server today.

Goal: widen the server to every track format Juicebox and IGV can load, without
weakening the deny-by-default posture and without regressing `.hic`.

## Constraints

- The container bind-mounts host `/` read-only at `/data`
  (`nginx/docker-compose.yml`). Every extension added to the allowlist becomes
  readable **from anywhere on the host filesystem**, by anyone who can reach
  port 8021. Extension choice is a security decision, not just a usability one.
- Deny-by-default must be preserved: anything not explicitly allowlisted 403s.
- `.hic` behavior must be byte-identical after the change.
- No build step, no new files, no dependency changes — this is a config edit.

## Scope

**In scope:** 1D/2D track files and their sidecar indexes.

**Explicitly out of scope** (decided during design, not oversights):

| Excluded | Reason |
|---|---|
| Alignments (`bam`/`bai`, `cram`/`crai`) | Large files, heavy Range traffic, exposes read-level sequence from any host path |
| Reference/genome (`fasta`, `fai`, `gzi`, `2bit`, `.genome`, `.chrom.sizes`) | Not needed; IGV loads references from its own hosted set |
| Session/config (`.xml`, `.json`, `.juicebox`, `.assembly`) | Session state, not track data |
| `.txt` | Juicebox loop lists are commonly `.txt`, but allowing it exposes every text file on the host. Rename loop lists to `.bedpe`, which Juicebox loads natively. |
| `.cool` / `.mcool` | Not an IGV or Juicebox track format. Not needed for now. |

## Approach

A `map` block at `http` level resolves `$uri` to a boolean `$track_ok`. A single
`location /` gates on it and carries one copy of the CORS block.

Two rejected alternatives:

- **One large regex location** — smallest diff, but collapses the allowlist into
  a dense unreadable alternation that must be edited in place to add a format.
- **Split locations + `include cors.conf`** — more idiomatic nginx, but adds a
  file and a Dockerfile `COPY` while buying nothing, since every family receives
  identical treatment.

The `map` approach keeps the allowlist a readable table, makes adding a format a
one-line change, and uses `if` only in the `if`+`return` form that nginx
documents as safe.

## Allowlist

```nginx
# Allowlist of IGV / Juicebox track file extensions.
# $track_ok = 1 means the URI may be served; anything else 403s.
map $uri $track_ok {
    default 0;

    # Hi-C contact matrices
    ~*\.hic$                                            1;

    # Signal tracks, binary (no .gz variant — already compressed/indexed)
    ~*\.(bigwig|bw|bigbed|bb|tdf)$                      1;

    # Signal tracks, text
    ~*\.(wig|bedgraph|bdg)(\.b?gz)?$                    1;

    # Feature / annotation tracks
    ~*\.(bed|gff|gff3|gtf|gvf|narrowpeak|broadpeak|gappedpeak|refgene|genepred|refflat|igv)(\.b?gz)?$  1;

    # Variants and segmented data
    ~*\.(vcf|seg|maf|mut|gwas)(\.b?gz)?$                1;

    # 2D annotations (Juicebox loops / domains)
    ~*\.(bedpe|longrange|interact|links)(\.b?gz)?$      1;

    # Tabix / igvtools sidecar indexes
    ~*\.(tbi|csi|idx)$                                  1;
}
```

Patterns use `~*` (case-insensitive), so real-world camelCase spellings such as
`narrowPeak`, `broadPeak`, and `bedGraph` match without separate entries.
`(\.b?gz)?` covers both `.gz` and bgzip's `.bgz` on text formats.

## Request handling

`location ~* \.hic$` is removed; its body moves into `location /`, gated by the
allowlist check:

```nginx
location / {
    # Deny-by-default: only allowlisted track extensions are served
    if ($track_ok = 0) {
        return 403;
    }

    # --- CORS preflight (OPTIONS) --- unchanged from current config
    if ($request_method = 'OPTIONS') { ... return 204; }

    # CORS headers on GET/HEAD responses — unchanged from current config
    add_header ... always;

    limit_except GET HEAD {
        deny all;
    }

    try_files $uri =404;
}
```

Ordering and header values are unchanged from what `.hic` receives today: the
same `Access-Control-*` set, the same `Accept-Ranges: bytes`, the same
OPTIONS→204 preflight, the same `limit_except GET HEAD`. The preflight `if` runs
in the rewrite phase, ahead of `limit_except` in the access phase, so OPTIONS
returns 204 rather than being denied — the current config already depends on
this.

`location = /health` is an exact match and continues to take priority over the
`/` prefix, so the health endpoint is unaffected.

Side effect worth noting: because the outer `add_header ... always` directives
apply to the 403 emitted by the allowlist check, denied requests now carry CORS
headers. This is harmless and mildly useful — a browser sees an honest 403
instead of an opaque CORS failure.

### Deliberately unchanged

- **`gzip` stays off.** Re-compressing bgzf, bigwig, or `.hic` costs CPU for no
  gain, and a compressed response would break the byte-range arithmetic that
  tabix and bigwig index lookups depend on.
- **`default_type application/octet-stream` stays.** `bed`, `wig`, `vcf`, and
  `bedgraph` are absent from nginx's `mime.types` and correctly fall through to
  octet-stream. `.gz` maps to `application/gzip` with no `Content-Encoding`
  header, so browsers will not silently inflate bgzf out from under igv.js.
- **Range serving needs no config.** It is the static module, already active.

## Files touched

- `nginx/nginx.conf` — the only production change.
- `nginx/test-tracks.sh` — new smoke test (see below).

Not touched: `nginx/Dockerfile`, `nginx/docker-compose.yml`, `index.html`, and
`hicstream.py` (the superseded Python server already accepts `--extensions`).

## Verification

`nginx -t` inside the built image, then a smoke script against a container
mounting a fixture directory:

| Case | Expect |
|---|---|
| `GET /fix.hic` | 200, `Accept-Ranges: bytes` — regression check |
| `GET /fix.bed`, `.bigwig`, `.vcf.gz`, `.bedpe`, `.tbi` | 200 + CORS headers |
| `GET /fix.bigwig` with `Range: bytes=10-19` | 206, `Content-Range: bytes 10-19/…`, correct 10 bytes |
| `OPTIONS /fix.bed` | 204 + `Access-Control-Allow-Origin: *` |
| `GET /etc/passwd`, `/fix.sh`, `/fix.txt` | 403 |
| `GET /missing.bed` | 404 |

If Docker is unavailable on the implementation host, `nginx -t` plus a
`map`-pattern unit check against the case table is the fallback, and the
container smoke test is deferred and reported as not run.
