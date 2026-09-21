#!/usr/bin/env bash
# The sh -c snippets below are single-quoted on purpose: the inner shell
# expands them.
# shellcheck disable=SC2016
set -uo pipefail
. ../../lib/common.sh

dir=${GM_RPM_DIR:?}
check 'rpmlint accepts the built packages' \
    rpmlint --config ../../../packaging/rpmlint.toml "${dir}"/*.rpm "${dir}"/srpm/*.rpm
finish
