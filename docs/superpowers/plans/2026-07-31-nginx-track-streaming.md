# nginx Track-File Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Widen the nginx streaming server from `.hic`-only to the full set of IGV and Juicebox track formats, and repair the CORS preflight that has never worked.

**Architecture:** A `map $uri $track_ok` block at `http` level resolves each request URI against a table of allowlisted extensions. A single `location /` gates on that variable with `if ($track_ok = 0) { return 403; }` and carries one copy of the CORS/Range header block. The regex `location ~* \.hic$` is removed and its body absorbed into `location /`.

**Tech Stack:** nginx 1.27-alpine in Docker, bash + curl for the smoke test. No build step, no package manager, no application code.

**Spec:** `docs/superpowers/specs/2026-07-31-nginx-track-streaming-design.md`

## Global Constraints

- **Docker requires `dangerouslyDisableSandbox: true`.** The daemon socket is blocked by the Claude Code sandbox: `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock`. `curl`, file edits, and `git` all work inside the sandbox normally — only `docker` needs the escape.
- **Do not disturb the running production container `hicstream-nginx`** (host port 8021). The smoke test binds port 18080 and its own fixture directory.
- **Deny-by-default is non-negotiable.** The container bind-mounts host `/` read-only at `/data`, so any extension added to the allowlist is readable from anywhere on the host by anyone who can reach the port. `default 0;` must stay the first line of the map.
- **Excluded by explicit decision, do not add:** `.txt`, `.cool`, `.mcool`, alignments (`bam`/`bai`/`cram`/`crai`), reference files (`fasta`/`fai`/`gzi`/`2bit`/`.genome`), session files (`.xml`/`.json`/`.juicebox`/`.assembly`).
- **`gzip` stays off** and **`default_type application/octet-stream` stays.** Compressing bgzf/bigwig would break the byte-range arithmetic tabix and bigwig index lookups depend on.
- Only two files change: `nginx/nginx.conf` and a new `nginx/test-tracks.sh`. Do not touch `nginx/Dockerfile`, `nginx/docker-compose.yml`, `index.html`, or `hicstream.py`.

---

## File Structure

| File | Responsibility |
|---|---|
| `nginx/nginx.conf` (modify) | The allowlist map + the single gated location. The only production change. |
| `nginx/test-tracks.sh` (create) | Self-contained smoke test: builds fixtures, runs a throwaway container, asserts the behavior matrix, cleans up after itself. |

---

### Task 1: Smoke test harness (fails against current config)

Write the test first. Against today's `.hic`-only config it must fail on every
non-`.hic` format and on the preflight — that failure is the proof the test is
actually exercising the behavior we're about to add.

**Files:**
- Create: `nginx/test-tracks.sh`

**Interfaces:**
- Consumes: `nginx/nginx.conf` (mounted read-only into the test container), `nginx:1.27-alpine`.
- Produces: an executable script; exit 0 = all assertions pass, exit 1 = at least one failed. Task 2 relies on nothing but that exit code.

- [ ] **Step 1: Write the failing test**

Create `nginx/test-tracks.sh`:

```bash
#!/usr/bin/env bash
# Smoke test for the HiCStat nginx track-streaming config.
#
#   Usage: nginx/test-tracks.sh
#
# Requires docker. The Claude Code sandbox blocks the docker socket, so run this
# with dangerouslyDisableSandbox: true. Uses port 18080 and a throwaway fixture
# directory so the live hicstream-nginx container (port 8021) is untouched.
set -uo pipefail

IMAGE="nginx:1.27-alpine"
CONTAINER="hicstream-nginx-test"
PORT="${TEST_PORT:-18080}"
CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nginx.conf"
FIXDIR="$(mktemp -d)"
BASE="http://localhost:$PORT"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    rm -rf "$FIXDIR"
}
trap cleanup EXIT

# ---------------- fixtures ----------------
bin() { head -c "$2" /dev/urandom > "$FIXDIR/$1"; }
bin fix.hic          4096
bin fix.bigwig       4096
bin fix.bw           1024
bin fix.bigbed       1024
bin fix.tdf          1024
bin fix.vcf.gz       1024
bin fix.vcf.gz.tbi    512
bin fix.bed.gz        512
bin fix.bed.gz.csi    512
printf 'chr1\t100\t200\tfeatA\n'                  > "$FIXDIR/fix.bed"
printf 'chr1\t100\t200\t5.0\n'                    > "$FIXDIR/fix.bedgraph"
printf 'chr1\t1\t2\tchr1\t3\t4\n'                 > "$FIXDIR/fix.bedpe"
printf 'chr1\tsrc\tgene\t1\t2\t.\t+\t.\tID=g1\n'  > "$FIXDIR/fix.gff3"
printf 'variableStep chrom=chr1\n1\t2.0\n'        > "$FIXDIR/fix.wig"
printf 'ID\tchrom\tstart\tend\tvalue\n'           > "$FIXDIR/fix.seg"
printf 'chr1\t1\t2\tp\t0\t.\t1\t1\t1\t1\n'        > "$FIXDIR/fix.narrowPeak"
printf 'chr1\t1\t2\tchr2:3-4,5\n'                 > "$FIXDIR/fix.longrange"
echo 'secret'    > "$FIXDIR/fix.txt"
echo '#!/bin/sh' > "$FIXDIR/fix.sh"
echo 'k=v'       > "$FIXDIR/fix.conf"
echo 'noext'     > "$FIXDIR/README"
mkdir -p "$FIXDIR/sub"
printf 'chr2\t1\t2\tx\n' > "$FIXDIR/sub/nested.bed"

# ---------------- server ----------------
docker rm -f "$CONTAINER" >/dev/null 2>&1
if ! docker run -d --name "$CONTAINER" -p "$PORT:8020" \
        -v "$CONF":/etc/nginx/nginx.conf:ro \
        -v "$FIXDIR":/data:ro "$IMAGE" >/dev/null; then
    echo "FATAL: docker run failed (is the daemon reachable? sandbox disabled?)" >&2
    exit 1
fi

ready=0
for _ in $(seq 1 40); do
    if curl -fsS -o /dev/null "$BASE/health" 2>/dev/null; then ready=1; break; fi
    sleep 0.25
done
if [ "$ready" -ne 1 ]; then
    echo "FATAL: server never became ready on $BASE/health" >&2
    docker logs "$CONTAINER" 2>&1 | tail -20 >&2
    exit 1
fi

# ---------------- assertions ----------------
PASS=0; FAIL=0
check() { # check <desc> <want> <got>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1)); printf '  ok    %-44s %s\n' "$1" "$3"
    else
        FAIL=$((FAIL+1)); printf '  FAIL  %-44s got=%s want=%s\n' "$1" "$3" "$2"
    fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
hdr() {  # hdr <url> <header-name-lowercase>
    curl -s -I "$1" | tr -d '\r' | awk -v h="$2" -F': ' \
        'tolower($1)==h {print $2; exit}'
}

echo "== allowlisted formats serve =="
for f in fix.hic fix.bigwig fix.bw fix.bigbed fix.tdf fix.bed fix.bedgraph \
         fix.bedpe fix.gff3 fix.wig fix.seg fix.narrowPeak fix.longrange \
         fix.vcf.gz fix.vcf.gz.tbi fix.bed.gz fix.bed.gz.csi sub/nested.bed; do
    check "GET /$f" 200 "$(code "$BASE/$f")"
done

echo "== non-allowlisted are denied =="
for f in fix.txt fix.sh fix.conf README etc/passwd; do
    check "GET /$f denied" 403 "$(code "$BASE/$f")"
done

echo "== range requests =="
rc=$(curl -s -H 'Range: bytes=10-19' -o "$FIXDIR/.range" -w '%{http_code}' "$BASE/fix.bigwig")
check "Range status"  206 "$rc"
check "Range length"  10  "$(wc -c < "$FIXDIR/.range" | tr -d ' ')"
check "Accept-Ranges" bytes "$(hdr "$BASE/fix.bed" accept-ranges)"

echo "== CORS =="
check "OPTIONS preflight"     204 "$(code -X OPTIONS "$BASE/fix.bed")"
check "preflight ACAO"        '*' "$(curl -s -i -X OPTIONS "$BASE/fix.bed" | tr -d '\r' \
                                     | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2; exit}')"
check "GET ACAO"              '*' "$(hdr "$BASE/fix.bed" access-control-allow-origin)"
check "OPTIONS on denied ext" 403 "$(code -X OPTIONS "$BASE/fix.txt")"

echo "== write methods rejected =="
for m in POST PUT DELETE; do
    check "$m denied" 403 "$(code -X "$m" "$BASE/fix.bed")"
done

echo "== misc =="
check "missing allowlisted file" 404 "$(code "$BASE/missing.bed")"
check "health endpoint"          200 "$(code "$BASE/health")"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x nginx/test-tracks.sh
```

- [ ] **Step 3: Run it against the CURRENT config to verify it fails**

Run (with `dangerouslyDisableSandbox: true`):

```bash
./nginx/test-tracks.sh; echo "exit=$?"
```

Expected: **exit=1**. `GET /fix.hic` passes (200) and the denied-extension cases
pass (403, since `location /` already blanket-403s), but every non-`.hic` format
returns 403 instead of 200, and `OPTIONS preflight` returns 403 instead of 204.
Roughly 17 assertions fail.

If the script instead reports `FATAL: docker run failed`, the sandbox is still
engaged — re-run with `dangerouslyDisableSandbox: true`.

- [ ] **Step 4: Commit**

```bash
git add nginx/test-tracks.sh
git commit -m "test: add smoke test for nginx track-file streaming

Currently fails: only .hic is allowlisted and the CORS preflight
returns 403. Both are fixed in the following commit."
```

---

### Task 2: Allowlist map + preflight fix

**Files:**
- Modify: `nginx/nginx.conf` — insert the map at `http` level (after `server_tokens off;`), replace `location ~* \.hic$` and `location /` with a single gated `location /`.

**Interfaces:**
- Consumes: the exit code of `nginx/test-tracks.sh` from Task 1.
- Produces: `$track_ok` (map variable, `0`/`1`) consumed only within this file. No downstream task depends on any other name.

- [ ] **Step 1: Replace the file contents**

Write `nginx/nginx.conf` exactly as follows. Note this both widens the allowlist
**and** adds `OPTIONS` to `limit_except` — the two changes are coupled, because a
widened allowlist is useless to browser clients whose preflight 403s.

```nginx
# HiCStat nginx configuration — genomics track streaming with Range & CORS support
# Replaces hicstream.py with native nginx static file serving

worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Performance
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 65;

    # Logging
    log_format main '$remote_addr - [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_range"';
    access_log /var/log/nginx/access.log main;

    # Disable server tokens for security
    server_tokens off;

    # Allowlist of IGV / Juicebox track file extensions.
    # $track_ok = 1 means the URI may be served; everything else 403s.
    # Patterns are case-insensitive (~*), so narrowPeak / bedGraph match as written.
    # (\.b?gz)? accepts the gzip and bgzip variants of the text formats.
    #
    # NOTE: the container mounts host / read-only at /data, so every extension
    # added here becomes readable from anywhere on the host. Keep `default 0`.
    map $uri $track_ok {
        default 0;

        # Hi-C contact matrices
        ~*\.hic$                                            1;

        # Signal tracks, binary (already compressed/indexed — no .gz variant)
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

    server {
        listen 8020;
        server_name _;

        # Serve files from /data (mounted host filesystem)
        root /data;

        # Disable directory listing
        autoindex off;

        location / {
            # Deny-by-default: only allowlisted track extensions are served
            if ($track_ok = 0) {
                return 403;
            }

            # --- CORS preflight (OPTIONS) ---
            if ($request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin'  '*';
                add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS, HEAD';
                add_header 'Access-Control-Allow-Headers' 'Range';
                add_header 'Access-Control-Expose-Headers' 'Content-Range, Content-Length, Accept-Ranges';
                add_header 'Access-Control-Max-Age' '86400';
                add_header 'Content-Length' '0';
                add_header 'Content-Type' 'text/plain';
                return 204;
            }

            # CORS headers on GET/HEAD responses
            add_header 'Access-Control-Allow-Origin'  '*' always;
            add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS, HEAD' always;
            add_header 'Access-Control-Allow-Headers' 'Range' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Range, Content-Length, Accept-Ranges' always;
            add_header 'Access-Control-Max-Age' '86400' always;
            add_header 'Accept-Ranges' 'bytes' always;

            # Only allow GET, HEAD, OPTIONS.
            #
            # OPTIONS MUST be listed here. limit_except routes every method NOT
            # listed into an implicit nested location containing only `deny all`,
            # and that nested context does not inherit the rewrite-phase `if`
            # above — so omitting OPTIONS makes the preflight block unreachable
            # and every browser preflight 403s. This was the pre-existing bug.
            limit_except GET HEAD OPTIONS {
                deny all;
            }

            # Serve the file
            try_files $uri =404;
        }

        # Health check endpoint
        location = /health {
            access_log off;
            add_header Content-Type text/plain;
            return 200 'ok';
        }
    }
}
```

- [ ] **Step 2: Validate syntax**

Run (with `dangerouslyDisableSandbox: true`):

```bash
docker run --rm -v "$PWD/nginx/nginx.conf":/etc/nginx/nginx.conf:ro \
    nginx:1.27-alpine nginx -t
```

Expected: `syntax is ok` and `test is successful`.

- [ ] **Step 3: Run the smoke test to verify it now passes**

Run (with `dangerouslyDisableSandbox: true`):

```bash
./nginx/test-tracks.sh; echo "exit=$?"
```

Expected: **exit=0**, `failed=0`, all assertions `ok`. In particular
`OPTIONS preflight` is now `204` and every allowlisted format is `200`.

If any allowlisted format still 403s, the corresponding map line did not match —
check the extension against the regex group it belongs to rather than adding a
new catch-all line.

- [ ] **Step 4: Confirm no unintended files changed**

```bash
git status --porcelain
```

Expected: only `nginx/nginx.conf` modified (`nginx/test-tracks.sh` was committed
in Task 1).

- [ ] **Step 5: Commit**

```bash
git add nginx/nginx.conf
git commit -m "feat: stream IGV/Juicebox track files, fix CORS preflight

Replace the .hic-only regex location with a map-based allowlist covering
signal tracks (bigwig/bw/bigbed/bb/tdf/wig/bedgraph), features (bed/gff/
gtf/narrowPeak/...), variants (vcf/seg/maf/gwas), 2D annotations (bedpe/
longrange/interact/links) and tabix/igvtools indexes, each with optional
.gz/.bgz. Deny-by-default is preserved via 'default 0'.

Also fixes a pre-existing bug where the CORS preflight always returned
403: limit_except routes unlisted methods into an implicit nested
location that does not inherit the rewrite-phase if, making the OPTIONS
handler unreachable. Adding OPTIONS to the permitted list fixes it while
POST/PUT/DELETE stay denied. Range is not a CORS-safelisted header, so
this blocked every browser-based igv.js/juicebox.js ranged fetch; IGV
desktop was unaffected because it performs no CORS negotiation."
```

---

### Task 3: Redeploy the live container

**Files:** none — deployment only.

**Interfaces:**
- Consumes: the committed `nginx/nginx.conf` from Task 2.
- Produces: the running `hicstream-nginx` container serving the new config on host port 8021.

> **Get the user's go-ahead before this task.** It restarts a live service.

- [ ] **Step 1: Capture the current live behavior as a baseline**

Run (sandbox is fine, this is just curl):

```bash
curl -s -o /dev/null -w 'live GET .hic -> %{http_code}\n' \
    http://localhost:8021/health
```

Expected: `200`. Record it; the same check must pass after the restart.

- [ ] **Step 2: Rebuild and restart**

Run (with `dangerouslyDisableSandbox: true`):

```bash
cd nginx && docker compose up -d --build && cd ..
```

Expected: `hicstream-nginx` recreated and `Started`.

- [ ] **Step 3: Verify the live service**

Run:

```bash
curl -s -o /dev/null -w 'health   -> %{http_code}\n' http://localhost:8021/health
curl -s -o /dev/null -X OPTIONS -w 'preflight -> %{http_code}\n' \
    http://localhost:8021/etc/hostname.bed
```

Expected: `health -> 200`. The preflight probe targets a non-existent but
allowlisted path, so `204` proves the preflight now works end-to-end on the live
service (preflight does not check file existence).

- [ ] **Step 4: Spot-check a real track file**

Pick an actual track file on the host and fetch its first bytes:

```bash
# substitute a real path under / that ends in an allowlisted extension
curl -s -o /dev/null -w '%{http_code} %{size_download}\n' \
    -H 'Range: bytes=0-99' http://localhost:8021/path/to/real.bigwig
```

Expected: `206 100`. If no real track file is handy on this host, note that this
step was skipped rather than marking it done.

- [ ] **Step 5: Confirm nothing else was disturbed**

```bash
docker ps --format '{{.Names}}\t{{.Status}}'
```

Expected: `hicstream-nginx` up, and the other pre-existing containers
(`caper-server`, `caper-postgresql`, `mcp-clickhouse`, `clickhouse`, `webssh2`,
`portainer_agent`, `buildx_buildkit_multiarch-builder0`) still running.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Allowlist table (all 7 families) | Task 2 Step 1 |
| Exclusions (`.txt`, `.cool`/`.mcool`, alignments, reference, sessions) | Global Constraints; asserted for `.txt` in Task 1 |
| Deny-by-default preserved | Task 2 Step 1 (`default 0`); asserted in Task 1 |
| CORS/Range headers unchanged | Task 2 Step 1; asserted in Task 1 |
| Preflight bug + `limit_except GET HEAD OPTIONS` fix | Task 2 Step 1; asserted in Task 1 |
| `gzip` off, `default_type` unchanged | Task 2 Step 1 (neither directive touched) |
| `location = /health` unaffected | Task 2 Step 1; asserted in Task 1 |
| Verification matrix | Task 1 Step 1 |
| Docker needs sandbox disabled | Global Constraints; repeated at each docker step |
| Don't disturb `hicstream-nginx` | Global Constraints; Task 3 Step 5 |

**Placeholder scan:** none — every step carries literal file content or a
runnable command. The one intentionally parameterized value is the real track
path in Task 3 Step 4, which cannot be known ahead of time and has an explicit
"note it was skipped" fallback.

**Type consistency:** `$track_ok` is the only introduced name, defined in Task 2
Step 1 and referenced only in the same block. `nginx/test-tracks.sh` is created
in Task 1 and invoked by the same path in Task 2. Port 18080 (test) and 8021
(live) are used consistently and never collide.
