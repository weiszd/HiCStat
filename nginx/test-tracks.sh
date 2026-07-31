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
# mktemp -d always makes this 0700, and the nginx image runs its worker
# as non-root uid 101 (nginx/Dockerfile: USER nginx) — without opening
# it up, the worker can't traverse into /data and every fixture 404s.
chmod 755 "$FIXDIR"
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

# --- security canaries: sensitive extensions that must never become
# allowlisted. If the map is ever widened to include one of these, this
# suite must go red rather than silently keep reporting failed=0
# (fix.sh already exists above as a non-allowlisted-are-denied fixture).
bin fix.pem     64
bin fix.env     64
bin fix.key     64
bin fix.db      64
bin fix.log     64
bin fix.yaml    64
bin fix.sqlite  64
bin fix.pack    64
bin fix.py      64

# --- deliberately-excluded extensions: dropped from the map due to
# namespace collisions with non-genomics files (git pack indexes,
# BitBake recipes, Debian packaging). Fixtures + assertions lock the
# decision in so a future re-add is a conscious choice, not a silent one.
bin fix.idx     64
bin fix.bb      64
bin fix.links   64

# --- extension-anchoring edge cases: prove the regexes are anchored with
# $ and that the optional (\.b?gz)? group can't stand alone ---
echo 'x' > "$FIXDIR/secret.bed.txt"
echo 'x' > "$FIXDIR/x.bedx"
echo 'x' > "$FIXDIR/x.bed.bak"
echo 'x' > "$FIXDIR/ok.bed."
echo 'x' > "$FIXDIR/secret.gz"
echo 'x' > "$FIXDIR/secret.bgz"

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
    if curl -fsS --connect-timeout 3 --max-time 10 -o /dev/null "$BASE/health" 2>/dev/null; then ready=1; break; fi
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
check_any() { # check_any <desc> <got> <want1> [want2 ...] — passes if got matches any want
    local desc="$1" got="$2"; shift 2
    for w in "$@"; do
        if [ "$w" = "$got" ]; then
            PASS=$((PASS+1)); printf '  ok    %-44s %s\n' "$desc" "$got"
            return
        fi
    done
    FAIL=$((FAIL+1)); printf '  FAIL  %-44s got=%s want one of=%s\n' "$desc" "$got" "$*"
}
# --connect-timeout/--max-time on every server-facing curl below: without
# them a hung nginx.conf change (deadlocked worker, bad timeout directive)
# blocks the script forever, the EXIT trap never fires, and the test
# container + $FIXDIR leak indefinitely. A timeout surfaces as curl's "000"
# http_code / empty header, which never matches a real expected value.
code() { curl -s --connect-timeout 3 --max-time 10 -o /dev/null -w '%{http_code}' "$@"; }
hdr() {  # hdr <url> <header-name-lowercase>
    curl -s --connect-timeout 3 --max-time 10 -I "$1" | tr -d '\r' | awk -v h="$2" -F': ' \
        'tolower($1)==h {print $2; exit}'
}

echo "== allowlist shape (extension set) =="
# The checks below only enumerate specific denied extensions (canaries,
# collisions, anchoring edge cases). None of them notice the allowlist
# itself growing -- adding e.g. ~*\.(json|xml|csv|ini|crt|pub|bak|sql)$ to
# the map would leave every existing check green and failed=0. On a
# container that bind-mounts host / read-only, silently widening the
# allowlist is a security change, not a refactor, so make it impossible to
# do by accident: parse the actual extension tokens out of the map in
# nginx.conf and diff them against this literal expected list. Any edit to
# the map -- add, remove, rename -- now has to touch this list too, so the
# person making the change has to look at what they're changing.
EXPECTED_EXTS="bdg bed bedgraph bedpe bigbed bigwig broadpeak bw csi gappedpeak genepred gff gff3 gtf gvf gwas hic igv interact longrange maf mut narrowpeak refflat refgene seg tbi tdf vcf wig"

actual_exts=$(sed -n '/map \$uri \$track_ok {/,/^    }/p' "$CONF" \
    | grep -E '^\s*~\*' \
    | sed -E 's/\(\\\.b\?gz\)\?//' \
    | grep -oE '\\\.\(?[A-Za-z0-9|]+\)?\$' \
    | sed -E 's/^\\\.\(?//; s/\)?\$$//' \
    | tr '|' '\n' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')
actual_exts="${actual_exts% }"

if [ "$actual_exts" = "$EXPECTED_EXTS" ]; then
    PASS=$((PASS+1)); printf '  ok    %-44s (%d extensions)\n' "map extension set matches expected" "$(echo "$actual_exts" | wc -w)"
else
    FAIL=$((FAIL+1))
    printf '  FAIL  %-44s\n' "map extension set changed -- update EXPECTED_EXTS if intentional"
    echo "    expected: $EXPECTED_EXTS"
    echo "    actual:   $actual_exts"
fi

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

echo "== sensitive-extension canaries (must stay denied) =="
for f in fix.pem fix.env fix.key fix.db fix.log fix.yaml fix.sqlite fix.pack fix.sh fix.py; do
    check "GET /$f denied" 403 "$(code "$BASE/$f")"
done

echo "== deliberately-excluded extensions (namespace collisions) =="
for f in fix.idx fix.bb fix.links; do
    check "GET /$f denied" 403 "$(code "$BASE/$f")"
done

echo "== extension-anchoring edge cases =="
for f in secret.bed.txt x.bedx x.bed.bak "ok.bed." secret.gz secret.bgz; do
    check "GET /$f denied" 403 "$(code "$BASE/$f")"
done

echo "== path traversal =="
# --path-as-is stops curl from normalizing dot-segments locally, so the
# raw request line actually reaches nginx as written.
# The unencoded ../ is normalized by nginx's own URI parser into
# /etc/passwd before the map is evaluated, so it 403s the same way a
# direct /etc/passwd request does. The percent-encoded forms bypass that
# early normalization and nginx may reject them outright with 400 before
# location matching even runs — accept 400 or 403 for those two rather
# than asserting a single code we have not actually observed.
check "dot-dot traversal (unencoded)" 403 "$(code --path-as-is "$BASE/fix.bed/../etc/passwd")"
check_any "dot-dot traversal (encoded slash)" "$(code --path-as-is "$BASE/fix.bed%2f..%2fetc%2fpasswd")" 400 403
check_any "dot-dot traversal (encoded dot)"   "$(code --path-as-is "$BASE/%2e%2e/etc/passwd")" 400 403

echo "== extensionless paths =="
check "GET / denied"     403 "$(code "$BASE/")"
check "GET /sub/ denied" 403 "$(code "$BASE/sub/")"

echo "== range requests =="
rc=$(curl -s --connect-timeout 3 --max-time 10 -H 'Range: bytes=10-19' -o "$FIXDIR/.range" -w '%{http_code}' "$BASE/fix.bigwig")
check "Range status"  206 "$rc"
check "Range length"  10  "$(wc -c < "$FIXDIR/.range" | tr -d ' ')"
check "Accept-Ranges" bytes "$(hdr "$BASE/fix.bed" accept-ranges)"

echo "== CORS =="
check "OPTIONS preflight"     204 "$(code -X OPTIONS "$BASE/fix.bed")"
check "preflight ACAO"        '*' "$(curl -s --connect-timeout 3 --max-time 10 -i -X OPTIONS "$BASE/fix.bed" | tr -d '\r' \
                                     | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2; exit}')"
check "GET ACAO"              '*' "$(curl -s --connect-timeout 3 --max-time 10 -D - -o /dev/null "$BASE/fix.bed" | tr -d '\r' \
                                     | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2; exit}')"
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
