#!/usr/bin/env bash
set -euo pipefail
args=("$@")
src=${args[-2]}
if [[ ${src} == *.previous ]]; then
    if [[ -n ${PUBLISH_MV_FAIL_ROLLBACK:-} ]]; then
        echo "publish-mv stub: refusing to roll back" >&2
        exit 1
    fi
elif [[ -n ${PUBLISH_MV_FAIL_PROMOTION:-} ]]; then
    echo "publish-mv stub: refusing to promote" >&2
    exit 1
fi
exec mv "$@"
