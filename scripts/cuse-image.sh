#!/usr/bin/env bash
# Make the pinned guest image for a target available and print its path.
#
# Usage: scripts/cuse-image.sh <target>
#
# The pins live in fixtures/cuse/images.tsv. Images are large and identical
# for every checkout, so the cache is per user, not per repository:
# ${XDG_CACHE_HOME:-~/.cache}/guildmaster-rpm/images, or IMAGE_CACHE_DIR. It
# also has to be outside the repository because tmt copies the whole fmf tree
# into every run.
#
# Cache rules, the same as for the source tarball in build-rpm.sh:
#   - a cached file is reused only if its bytes match the pinned SHA-256, and
#     that is checked on every use, so a truncated or altered file is replaced
#     rather than booted;
#   - a download goes to a per-invocation temporary file, is verified, and is
#     then published with one rename, so concurrent invocations can neither
#     see nor produce a partial image;
#   - the published file is made read-only. Guests never write to it: tmt
#     boots a throw-away copy-on-write overlay per run, and cuse-guest.sh
#     checks the base image's checksum again after each run.
#
# The cached file is named <first 16 hex digits of its SHA-256>-<file name>.
# tmt links images into its own store by base name; putting the content's
# identity in the name keeps two differently pinned checkouts from colliding
# there.
#
# The path is the only thing written to stdout. Events go to stderr. The URL
# is never logged in case it has been overridden with one carrying a token.
# CURL and SHA256SUM are seams for scripts/tests.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <target>" >&2
    exit 2
fi
target=$1

repo_root=$(cd "$(dirname "$0")/.." && pwd)
: "${CURL:=curl}"
: "${SHA256SUM:=sha256sum}"
: "${IMAGES_TSV:=${repo_root}/fixtures/cuse/images.tsv}"
: "${IMAGE_CACHE_DIR:=${XDG_CACHE_HOME:-${HOME}/.cache}/guildmaster-rpm/images}"
: "${IMAGE_ARCH:=$(uname -m)}"

download_tmp=

# log_event <event> [field...]: print a structured "image_event" log line
# to stderr.
#
# Writes "image_event event=<event> target=<target>" followed by each
# extra field (already "key=value" formatted) space-separated. Always
# returns 0.
log_event() {
    local event=$1
    shift
    printf 'image_event event=%s target=%s' "${event}" "${target}" >&2
    local field
    for field in "$@"; do
        printf ' %s' "${field}" >&2
    done
    printf '\n' >&2
}

# die <message>: log a failure and abort the script.
#
# Logs an image_failed event with <message> as its detail, prints
# "$0: <message>" to stderr, then exits the script with status 1.
die() {
    log_event image_failed "detail=\"$*\""
    echo "$0: $*" >&2
    exit 1
}

# cleanup: remove an in-progress download's temporary file, if any.
#
# Reads the "download_tmp" global and removes it when set and present.
# Always returns 0. Invoked from the EXIT, INT and TERM traps.
cleanup() {
    if [[ -n ${download_tmp} && -e ${download_tmp} ]]; then
        rm -f "${download_tmp}"
    fi
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# redact_secrets: strip credentials and query strings from stdin.
#
# Filters stdin to stdout, replacing any userinfo before an "@" in a URL
# with "REDACTED" and any query string with "?REDACTED".
redact_secrets() {
    sed -E -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/[:space:]]*@#\1REDACTED@#g' \
        -e 's#\?[^[:space:]]*#?REDACTED#g'
}

pin=$(awk -F'\t' -v target="${target}" -v arch="${IMAGE_ARCH}" \
    '$0 !~ /^#/ && $1 == target && $2 == arch' "${IMAGES_TSV}")
[[ -n ${pin} ]] || die "no image is pinned for ${target} on ${IMAGE_ARCH} in ${IMAGES_TSV}"
[[ $(wc -l <<<"${pin}") -eq 1 ]] || die "more than one image is pinned for ${target} on ${IMAGE_ARCH}"
IFS=$'\t' read -r _ _ image_name image_sha256 image_url <<<"${pin}"
[[ ${image_sha256} =~ ^[0-9a-f]{64}$ ]] || die "the pinned SHA-256 for ${target} is malformed"
# IMAGE_URL overrides where the bytes come from (a mirror, a local file://
# copy), never which bytes are acceptable.
image_url=${IMAGE_URL:-${image_url}}

cached=${IMAGE_CACHE_DIR}/${image_sha256:0:16}-${image_name}

# checksum_matches <file>: test whether <file> matches the pinned SHA-256.
#
# Returns 1 when <file> does not exist; otherwise returns SHA256SUM's
# status for verifying <file> against image_sha256.
checksum_matches() {
    [[ -f $1 ]] || return 1
    echo "${image_sha256}  $1" | "${SHA256SUM}" -c --status -
}

mkdir -p "${IMAGE_CACHE_DIR}"
if checksum_matches "${cached}"; then
    log_event cache_hit "image=${image_name}" "sha256=${image_sha256}"
else
    if [[ -e ${cached} ]]; then
        log_event cache_corrupt "image=${image_name}"
    else
        log_event cache_miss "image=${image_name}"
    fi
    log_event download_start "image=${image_name}"
    download_tmp=$(mktemp "${IMAGE_CACHE_DIR}/${image_name}.XXXXXX")
    if ! curl_stderr=$("${CURL}" -fsSL -o "${download_tmp}" "${image_url}" 2>&1 >/dev/null); then
        die "download of ${image_name} failed: $(redact_secrets <<<"${curl_stderr}" | tr '\n' ' ')"
    fi
    if ! checksum_matches "${download_tmp}"; then
        log_event checksum_failed "image=${image_name}"
        die "checksum mismatch for downloaded ${image_name}; nothing was cached"
    fi
    chmod 0444 "${download_tmp}"
    mv -f "${download_tmp}" "${cached}"
    download_tmp=
    log_event cache_published "image=${image_name}" "sha256=${image_sha256}"
fi

printf '%s\n' "${cached}"
