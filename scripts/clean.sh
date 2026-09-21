#!/usr/bin/env bash
# Remove build output and the cached upstream tarball.
#
# Usage: scripts/clean.sh
#
# Clean is serialized against every build: scripts/build-rpm.sh holds
# .build/locks/activity.lock shared for its whole run, and this script takes
# the same lock exclusively, so it waits for in-flight builds to finish and
# no build can start while it is removing anything. That is what keeps it
# from deleting a directory a build is currently publishing into.
#
# Two things inside the cache are deliberately preserved.
#
# .build/locks/ holds the lock files themselves. Removing a lock file while
# holding a lock on it would let a waiting process take a lock on the unlinked
# inode and proceed as though it had exclusive access.
#
# .build/images/ holds the checksum-verified guest images used by the CUSE
# acceptance tier. They are about a gigabyte, take a long time to fetch, and
# are not build output, so a routine clean keeps them. CLEAN_IMAGES=1 removes
# them too, for the rare case where the pinned image itself must be refetched.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

: "${FLOCK:=flock}"
: "${CACHE_DIR:=${repo_root}/.build}"
: "${LOCK_DIR:=${CACHE_DIR}/locks}"
: "${IMAGE_DIR:=${CACHE_DIR}/images}"
: "${DIST_DIR:=${repo_root}/dist}"
# Set to 1 to remove the verified guest images as well.
: "${CLEAN_IMAGES:=}"
# Test seam: a command run immediately before blocking on the lock, which
# lets the unit tests observe the waiting state without a timing sleep.
: "${CLEAN_PRELOCK_HOOK:=}"

[[ -n ${CACHE_DIR} && -n ${DIST_DIR} ]] ||
    {
        echo "$0: CACHE_DIR and DIST_DIR must not be empty" >&2
        exit 2
    }

mkdir -p "${LOCK_DIR}"

if [[ -n ${CLEAN_PRELOCK_HOOK} ]]; then
    "${CLEAN_PRELOCK_HOOK}"
fi

exec {activity_fd}>"${LOCK_DIR}/activity.lock"
"${FLOCK}" -x "${activity_fd}"

rm -rf "${DIST_DIR}"

# Everything in the cache except the preserved directories.
kept=("$(basename "${LOCK_DIR}")")
if [[ ${CLEAN_IMAGES} != 1 ]]; then
    kept+=("$(basename "${IMAGE_DIR}")")
fi

if [[ -d ${CACHE_DIR} ]]; then
    find_args=()
    for name in "${kept[@]}"; do
        find_args+=(! -name "${name}")
    done
    find "${CACHE_DIR}" -mindepth 1 -maxdepth 1 "${find_args[@]}" -exec rm -rf {} +
fi

exec {activity_fd}>&-

if [[ ${CLEAN_IMAGES} == 1 ]]; then
    echo "Removed ${DIST_DIR}, the cached tarball and ${IMAGE_DIR}; kept ${LOCK_DIR}"
else
    echo "Removed ${DIST_DIR} and the cached tarball; kept ${LOCK_DIR} and ${IMAGE_DIR}"
fi
