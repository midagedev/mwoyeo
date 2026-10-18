#!/bin/bash
# Fetches the PDF and the LaTeX source (e-print) of every paper in papers.tsv from arXiv (arxiv.org only), pinned to the version in
# the table, and checks that the abs page still shows the license recorded there. Nothing is kept in the repo: files go to the cache.
#   usage: fetch.sh [cache dir]                      (default /tmp/l0/keep-labels-cache; env KEEP_CACHE)
# A file already in the cache is not fetched again; its sha256 must equal the table's when the table has one (a paper changed on
# arXiv under the same version would change the labels, so that is an error, not a warning).
HERE=$(cd "$(dirname "$0")" && pwd)
CACHE=${1:-${KEEP_CACHE:-/tmp/l0/keep-labels-cache}}
mkdir -p "$CACHE"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
get() { # url out
    [ -s "$2" ] && return 0
    sleep 3                                           # arXiv asks for no more than one request in three seconds
    curl -sSL -m 180 --fail "$1" -o "$2.part" && mv "$2.part" "$2"
}
rc=0
while IFS=$'\t' read -r id ver set license pages pdf_sha src_sha; do
    [ "$id" = id ] && continue
    abs="$CACHE/$id.abs.html"
    get "https://arxiv.org/abs/${id}v${ver}" "$abs" || { echo "FAIL abs $id"; rc=1; continue; }
    if ! grep -q "$license" "$abs"; then echo "FAIL $id: license line '$license' not on the abs page"; rc=1; continue; fi
    get "https://arxiv.org/pdf/${id}v${ver}" "$CACHE/$id.pdf" || { echo "FAIL pdf $id"; rc=1; continue; }
    get "https://arxiv.org/e-print/${id}v${ver}" "$CACHE/$id.src" || { echo "FAIL src $id"; rc=1; continue; }
    for kind in pdf src; do
        want=$([ $kind = pdf ] && echo "$pdf_sha" || echo "$src_sha"); have=$(sha "$CACHE/$id.$kind")
        if [ -n "$want" ] && [ "$want" != "-" ] && [ "$want" != "$have" ]; then echo "FAIL $id.$kind sha256 $have != table $want"; rc=1; fi
        [ "$want" = "-" ] && echo "note $id.$kind sha256 $have (table has none yet)"
    done
    echo "ok $id v$ver $set"
done < "$HERE/papers.tsv"
exit $rc
