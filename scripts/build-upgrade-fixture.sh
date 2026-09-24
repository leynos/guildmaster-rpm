#!/usr/bin/env bash
# Build the higher-release package that the upgrade tests install over the
# package under test.
#
# Usage: scripts/build-upgrade-fixture.sh <image> <target>
#
# The fixture is a rebuild of the target's own published source RPM with
# ".upgradetest" appended to the dist tag, so its release sorts after the
# real one and everything else is identical. It is test equipment: it is
# written to .build/upgrade-fixture/<target>/, never to dist/, and is never
# published. Rebuilding on the host side keeps build dependencies out of the
# guests, where they would hide a missing runtime dependency.
#
# The output directory is replaced whole. "mv -T --exchange" (renameat2
# RENAME_EXCHANGE) swaps the previous fixture and the new one atomically when
# the host supports it; otherwise the previous fixture is moved aside to
# "<out_dir>.old", the new one is moved into place, and ".old" is removed only
# once the promotion has succeeded. If this script is interrupted between the
# move-aside and the promotion, the INT/TERM traps move ".old" back rather
# than deleting the staging directory and leaving no output at all; a later
# run restores a leftover ".old" at start-up for the same reason, rather than
# deleting it as clutter before it can be recovered. The activity lock is held
# shared so that "make clean" cannot run underneath the build, and the
# per-target fixture lock is held throughout, including across this
# recovery.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <image> <target>" >&2
    exit 2
fi
image=$1
target=$2

repo_root=$(cd "$(dirname "$0")/.." && pwd)
: "${PODMAN:=podman}"
: "${FLOCK:=flock}"
: "${CACHE_DIR:=${repo_root}/.build}"
: "${LOCK_DIR:=${CACHE_DIR}/locks}"
: "${DIST_DIR:=${repo_root}/dist}"
# Used only for the fallback promotion move, so a test stub cannot disturb
# any other rename in this script. See scripts/build-rpm.sh, which uses the
# same seam for the same reason.
: "${PUBLISH_MV:=mv}"
# Used only for the fallback's move-aside of the previous fixture, so the
# cancellation tests can hold that move open after its rename completes.
: "${PUBLISH_ASIDE_MV:=mv}"
# "never" forces the non-atomic fallback below; the unit tests use it to
# cover both publication paths on any host.
: "${PUBLISH_EXCHANGE:=auto}"

case ${target} in
fedora-43) dist=.fc43 ;;
rocky-10) dist=.el10 ;;
*)
    echo "$0: unknown target ${target}" >&2
    exit 2
    ;;
esac

out_root=${CACHE_DIR}/upgrade-fixture
out_dir=${out_root}/${target}
old_dir=${out_dir}.old
staging=
# Set to old_dir immediately before the fallback publish path moves the
# previous fixture aside, and cleared once promotion or rollback has
# completed on every branch. Lets cleanup recognize a cancellation inside
# that window and restore the previous fixture to out_dir rather than
# leaving it stranded at old_dir, or leaving out_dir empty altogether. It is
# armed before the move because bash defers a trap until the running command
# returns: a signal delivered during the move-aside runs cleanup after the
# rename has completed. An armed marker is harmless if the move never
# happened, because cleanup restores only when out_dir is absent.
fallback_previous=

# cleanup: remove the in-progress staging directory, and restore a fixture
# stranded mid-promotion by cancellation.
#
# Reads the "staging" global and removes it when set and present. When
# "fallback_previous" is set, out_dir is absent and fallback_previous is
# present, moves fallback_previous back to out_dir rather than deleting it,
# so a SIGINT/SIGTERM arriving between the move-aside and the promotion never
# loses the only remaining copy of the previous fixture. Always returns 0.
# Invoked from the EXIT, INT and TERM traps.
cleanup() {
    if [[ -n ${staging} && -e ${staging} ]]; then
        rm -rf "${staging}"
    fi
    if [[ -n ${fallback_previous} && ! -e ${out_dir} && -e ${fallback_previous} ]]; then
        if mv -T "${fallback_previous}" "${out_dir}"; then
            echo "$0: restored the previous upgrade fixture for ${target} after cancellation" >&2
        else
            echo "$0: could not restore the previous upgrade fixture for ${target} after cancellation; it is preserved at ${fallback_previous}" >&2
        fi
    fi
    staging=
    fallback_previous=
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

mkdir -p "${LOCK_DIR}" "${out_root}"
exec {activity_fd}>"${LOCK_DIR}/activity.lock"
"${FLOCK}" -s "${activity_fd}"

# A missing directory must reach the diagnostic below, not stop set -e.
srpm=$(find "${DIST_DIR}/${target}/srpm" -maxdepth 1 -name 'guildmaster-*.src.rpm' 2>/dev/null || true)
[[ -n ${srpm} && $(wc -l <<<"${srpm}") -eq 1 ]] || {
    echo "$0: expected exactly one source RPM in ${DIST_DIR}/${target}/srpm; run make rpm-${target}" >&2
    exit 1
}

# One build per target at a time. The lock is held until the new directory
# is published, so a second invocation waits and then reuses the result.
exec {fixture_fd}>"${LOCK_DIR}/upgrade-fixture-${target}.lock"
"${FLOCK}" -x "${fixture_fd}"

# Recover from a run interrupted between the move-aside and the promotion: an
# ".old" left behind with out_dir absent is the only copy of the previous
# fixture, so restore it before anything else touches out_dir or old_dir.
if [[ ! -e ${out_dir} && -e ${old_dir} ]]; then
    mv -T "${old_dir}" "${out_dir}"
    echo "$0: restored the previous upgrade fixture for ${target} left over from an interrupted run" >&2
fi

# Reuse a fixture that was built from this exact source RPM.
srpm_sum=$(sha256sum <"${srpm}" | cut -d' ' -f1)
if [[ -f ${out_dir}/source.sha256 && $(cat "${out_dir}/source.sha256") == "${srpm_sum}" ]]; then
    echo "upgrade fixture for ${target} is current"
    exit 0
fi

staging=$(mktemp -d "${out_root}/${target}.XXXXXX")
# The single-quoted script is expanded by the container's shell.
# shellcheck disable=SC2016
"${PODMAN}" run --rm \
    -v "${srpm}:/work/guildmaster.src.rpm:ro,z" \
    -v "${staging}:/out:z" \
    -e "UPGRADE_DIST=${dist}.upgradetest" \
    "${image}" \
    bash -c '
        set -euo pipefail
        {
            dnf -y install rpm-build dnf-plugins-core
            # The same detection and dnf4/dnf5 spellings as build-rpm.sh.
            if grep -q "^ID=\"\?rocky\"\?$" /etc/os-release; then
                dnf -y config-manager --set-enabled crb ||
                    dnf -y config-manager setopt crb.enabled=1
            fi
            dnf -y builddep /work/guildmaster.src.rpm
        } >/tmp/deps.log 2>&1 || {
            tail -n 40 /tmp/deps.log
            exit 1
        }
        rpmbuild --rebuild --define "dist ${UPGRADE_DIST}" \
            /work/guildmaster.src.rpm >/tmp/rebuild.log 2>&1 || {
            tail -n 40 /tmp/rebuild.log
            exit 1
        }
        cp /root/rpmbuild/RPMS/*/guildmaster-[0-9]*.rpm /out/
    '
printf '%s\n' "${srpm_sum}" >"${staging}/source.sha256"
chmod 0755 "${staging}"

if [[ ! -e ${out_dir} ]]; then
    # First build for this target: a plain rename into a free name is atomic.
    mv -T "${staging}" "${out_dir}"
    staging=
elif [[ ${PUBLISH_EXCHANGE} != never ]] &&
    mv -T --exchange "${staging}" "${out_dir}" 2>/dev/null; then
    # ${staging} now holds the superseded fixture; drop it. At no point was
    # out_dir absent, so there is nothing for a concurrent cancellation to
    # restore here.
    rm -rf "${staging}"
    staging=
else
    # out_dir is briefly absent from the move-aside until promotion (or
    # rollback) completes. cleanup restores it from old_dir if this process
    # is cancelled inside that window, including during the move-aside
    # itself, so the marker is armed before the move.
    fallback_previous=${old_dir}
    if ! "${PUBLISH_ASIDE_MV}" -T "${out_dir}" "${old_dir}"; then
        fallback_previous=
        echo "$0: could not move the previous upgrade fixture for ${target} aside" >&2
        exit 1
    fi

    if "${PUBLISH_MV}" -T "${staging}" "${out_dir}"; then
        rm -rf "${old_dir}"
        fallback_previous=
        staging=
    else
        echo "$0: promoting the new upgrade fixture for ${target} failed" >&2
        if "${PUBLISH_MV}" -T "${old_dir}" "${out_dir}"; then
            fallback_previous=
            echo "$0: restored the previous upgrade fixture for ${target}" >&2
        else
            fallback_previous=
            echo "$0: could not restore the previous upgrade fixture for ${target}; it is preserved at ${old_dir}" >&2
        fi
        exit 1
    fi
fi
ls -l "${out_dir}"
