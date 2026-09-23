#!/usr/bin/env bash
set -euo pipefail
out=
while [[ $# -gt 0 ]]; do
    case $1 in
    -o)
        out=$2
        shift 2
        ;;
    *) shift ;;
    esac
done
cat "${CURL_STUB_FIXTURE}" >"${out}"
