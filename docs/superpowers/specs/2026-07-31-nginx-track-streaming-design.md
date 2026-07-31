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
    ~*\.(bigwig|bw|bigbed|tdf)$                         1;

    # Signal tracks, text
    ~*\.(wig|bedgraph|bdg)(\.b?gz)?$                    1;

    # Feature / annotation tracks
    ~*\.(bed|gff|gff3|gtf|gvf|narrowpeak|broadpeak|gappedpeak|refgene|genepred|refflat|igv)(\.b?gz)?$  1;

    # Variants and segmented data
    ~*\.(vcf|seg|maf|mut|gwas)(\.b?gz)?$                1;

    # 2D annotations (Juicebox loops / domains)
    ~*\.(bedpe|longrange|interact)(\.b?gz)?$            1;

    # Tabix sidecar indexes
    ~*\.(tbi|csi)$                                      1;
}
```

### Extension-namespace collisions (post-review revision)

The security review of the implemented config flagged that on a mount
exposing host `/`, several extensions collide with unrelated file types, and
verified live 200 responses for `/pack-abc.idx` and `/contacts.vcf`. Three
were dropped from the table above by decision:

| Dropped | Collides with | Why the loss is acceptable |
|---|---|---|
| `.idx` | git pack indexes (`.git/objects/pack/pack-<sha>.idx`) | igvtools-only; tabix `.tbi`/`.csi` are kept and cover the common case |
| `.bb` | BitBake recipe files | redundant with `.bigbed`, which is kept |
| `.links` | Debian packaging files | rare next to `.bedpe`/`.longrange`, both kept |

**`.vcf` was deliberately kept** despite overlapping with vCard contact
exports, which are arguably likelier than genomics VCFs on a machine's root
filesystem. VCF is a primary IGV variant track format; dropping it would
remove variant support from the server entirely. This is an accepted,
explicit trade-off, not an oversight.

The smoke test asserts all three dropped extensions return 403, so re-adding
one turns the suite red rather than silently widening the surface.

`Access-Control-Allow-Origin: *` was reviewed and deliberately left
unchanged. It already was `*` for `.hic`; the readable surface widened from
one extension to roughly thirty, which is a reachability question for the
port rather than a header question.

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

    # OPTIONS must be listed here or the preflight above is unreachable —
    # see "Pre-existing bug: CORS preflight has never worked" below
    limit_except GET HEAD OPTIONS {
        deny all;
    }

    try_files $uri =404;
}
```

Header values are unchanged from what `.hic` receives today: the same
`Access-Control-*` set, the same `Accept-Ranges: bytes`, the same OPTIONS→204
preflight block.

### Pre-existing bug: CORS preflight has never worked

An earlier draft of this spec claimed the preflight `if` runs in the rewrite
phase ahead of `limit_except` in the access phase, so OPTIONS returns 204. That
is **wrong**, and was verified wrong against the current `master` config:

```
PRODUCTION config, OPTIONS /fix.hic -> 403   (expected 204)
PRODUCTION config, GET     /fix.hic -> 200
```

Isolating one variable at a time in a four-server-block test pinned the cause:

| Variant | OPTIONS result |
|---|---|
| OPTIONS-`if` alone | 204 |
| OPTIONS-`if` + `limit_except GET HEAD` | **403** |
| allowlist-`if` + OPTIONS-`if`, no `limit_except` | 204 |
| both `if`s + `limit_except GET HEAD` | **403** |

`limit_except` is the only variable that changes the outcome; stacked `if`
blocks are harmless. The mechanism: **`limit_except` creates an implicit nested
location for the methods not listed.** OPTIONS is routed into that nested
context, which contains nothing but `deny all`, and the parent location's
rewrite-phase `if` is not inherited into it — so `return 204` is unreachable and
the request 403s at the access phase.

**Fix:** list OPTIONS among the permitted methods so it reaches the preflight
handler, while write methods stay denied:

```nginx
limit_except GET HEAD OPTIONS {
    deny all;
}
```

Verified against the corrected config:

```
OPTIONS /fix.bed -> 204 + Access-Control-Allow-Origin/-Methods/-Headers
GET     /fix.bed -> 200
POST    /fix.bed -> 403      PUT -> 403      DELETE -> 403
OPTIONS /fix.txt -> 403      (not allowlisted — allowlist still gates preflight)
```

**Why this went unnoticed and why it now matters.** `Range` is not a
CORS-safelisted request header, so any *browser* client issuing a ranged
cross-origin fetch must preflight first — and that preflight has been failing.
IGV **desktop** is a Java client that performs no CORS negotiation at all, so it
was never affected, which is the likely reason the bug went unreported. But
igv.js and juicebox.js are exactly the browser clients this change targets, so
shipping the widened allowlist without this fix would leave every new format
unloadable from a browser. The fix is therefore in scope, not an incidental
drive-by.

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
| `GET /fix.bed`, `.bigwig`, `.vcf.gz`, `.vcf.gz.tbi`, `.bedpe` | 200 + CORS headers |
| `GET /fix.bigwig` with `Range: bytes=10-19` | 206, `Content-Range: bytes 10-19/…`, exactly 10 bytes |
| `OPTIONS /fix.bed` | 204 + `Access-Control-Allow-Origin: *` — the regression guard for the preflight bug |
| `POST`/`PUT`/`DELETE` `/fix.bed` | 403 — write methods stay denied after adding OPTIONS to `limit_except` |
| `OPTIONS /fix.txt` | 403 — allowlist gates preflight too |
| `GET /etc/passwd`, `/fix.sh`, `/fix.txt` | 403 |
| `GET /missing.bed` | 404 |
| `GET /health` | 200 `ok` |

Docker is available on this host, but **the daemon socket is blocked by the
Claude Code sandbox** — `docker` reports `permission denied while trying to
connect to the docker API at unix:///var/run/docker.sock`. All `docker` commands
in the implementation must run with `dangerouslyDisableSandbox: true`. `curl`
works inside the sandbox normally.

The live production container `hicstream-nginx` (host port 8021) must not be
disturbed by testing; the smoke test binds its own high port and its own
fixture directory.
