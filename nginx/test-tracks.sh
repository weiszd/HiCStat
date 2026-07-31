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
