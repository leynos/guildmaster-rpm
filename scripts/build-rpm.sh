#!/usr/bin/env bash
# Build the guildmaster RPMs inside podman containers for a given target.
#
# Usage: scripts/build-rpm.sh <image> <outdir>
#   <image>   container image to build in (e.g. registry.fedoraproject.org/fedora:43)
#   <outdir>  directory to place the built RPMs in (relative to the repo root).
#             Its basename names the target: fedora-43 or rocky-10.
#
# Ownership model
#   .build/            the checksum-verified upstream tarball cache, plus
#                      .build/locks/. Shared by every target and every
#                      concurrent invocation; owned by no single build.
#   <outdir>/          published output. Only ever replaced whole, by the
#                      publish step below. Never mounted into a container.
#   <outdir>/../.staging/
#                      per-invocation staging directories. Each belongs to
#                      exactly one invocation, which removes its own on exit.
#                      A <staging>.previous directory is recovery data and is
#                      deliberately never removed by cleanup.
#   make clean         removes dist/ and the cached tarball, keeping
#                      .build/locks/; see scripts/clean.sh.
#
# Locking
#   .build/locks/activity.lock       held SHARED for the whole of this script.
#                                    scripts/clean.sh takes it EXCLUSIVE, so
#                                    clean never runs while a build is active.
#   .build/locks/publish-<name>.lock held EXCLUSIVE across the publish step,
#                                    so two builds of the same target cannot
#                                    interleave their swaps.
#
# The three container phases
#   A  a named container installs rpm-build, dnf-plugins-core and the spec's
#      build dependencies (enabling CRB on Rocky, where meson lives). This is
#      the only phase with a network. It is committed to a temporary image.
#   B  that image runs rpmbuild -ba with --network=none, copies the binary,
#      debuginfo and debugsource packages to /out and the SRPM to /out/srpm,
#      writes /out/manifest.tsv, and refuses payload paths outside the
#      permitted roots.
#   C  that image rebuilds the SRPM from scratch, again with --network=none,
#      and fails unless the rebuild yields the same set of package names.
#   The container and image names carry this invocation's build id; cleanup
#   removes those two names and nothing else.
#
# Diagnostics
#   Lifecycle events are written to stdout as single-line key=value records
#   prefixed with "build_event", so a CI log can be grepped or parsed. Every
#   record carries event, target, build_id and elapsed_seconds. A free-form
#   detail="..." field, when present, is always last.
#
#   Secrets never reach the log. TARBALL_URL is overridable and may carry
#   userinfo or a query token, so it is never logged, in whole or in part;
#   downloads are reported by tarball filename only, and any diagnostic
#   captured from curl is passed through redact_secrets first.
#
# Every external command and every input pinned below can be overridden from
# the environment. Real builds override none of them; the seams exist so
# scripts/tests/test-build-rpm.sh can drive the download, caching,
# orchestration, validation and publication logic against stub commands and a
# local fixture, without a network or a container runtime.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <image> <outdir>" >&2
    exit 2
fi

image=$1
outdir=$2

repo_root=$(cd "$(dirname "$0")/.." && pwd)

# <outdir> is normally relative to the repo root; an absolute path is taken
# as given, which is what the unit tests use to stay out of the checkout.
if [[ ${outdir} == /* ]]; then
    outdir_path=${outdir}
else
    outdir_path=${repo_root}/${outdir}
fi
target_name=$(basename "${outdir_path}")

# Injectable command seams.
: "${CURL:=curl}"
: "${SHA256SUM:=sha256sum}"
: "${PODMAN:=podman}"
: "${FLOCK:=flock}"
# Used only for the two publication moves on the fallback path: promoting
# staging to the output path, and rolling the previous output back if that
# promotion fails. Scoped this narrowly so a test stub cannot disturb the
# unrelated renames in this script.
: "${PUBLISH_MV:=mv}"

# Injectable inputs.
: "${COMMIT:=463382ba5b47625a9355832cd792a164c54237f9}"
commit=${COMMIT}
short_commit=${commit:0:7}
tarball="guildmaster-${commit}.tar.gz"
: "${TARBALL_URL:=https://codeberg.org/amonakov/guildmaster/archive/${commit}.tar.gz}"
: "${TARBALL_SHA256:=825b1a2c5748eb89d57fe6ef1435c1bf8d33656a696f9f5ca6b87b0965ccbfcb}"
: "${SPEC_FILE:=${repo_root}/guildmaster.spec}"
: "${PACKAGING_DIR:=${repo_root}/packaging}"
: "${PATCHES_DIR:=${repo_root}/patches}"
: "${CACHE_DIR:=${repo_root}/.build}"
: "${LOCK_DIR:=${CACHE_DIR}/locks}"
# Staging sits beside the published directory so that promoting it is a
# rename within one filesystem rather than a copy.
: "${STAGING_ROOT:=$(dirname "${outdir_path}")/.staging}"
# "never" forces the non-atomic fallback in publish_staging; the unit tests
# use it to cover both publication paths on any host.
: "${PUBLISH_EXCHANGE:=auto}"
# The package is native, so a noarch or foreign-arch result is a defect.
: "${EXPECTED_ARCH:=x86_64}"

tarball_url=${TARBALL_URL}
tarball_sha256=${TARBALL_SHA256}
cache_dir=${CACHE_DIR}
spec_file=${SPEC_FILE}
spec_name=$(basename "${spec_file}")

download_tmp=
staging_dir=
deps_container=
temp_image=

# Identifies this invocation in the log, and in the container and image names
# it creates. Derived from the pid and bash's seeded RANDOM; carries no
# information about the inputs, so it is safe to publish in CI artefacts.
build_id="$$-${RANDOM}"

# One structured diagnostic record. Extra arguments are appended verbatim and
# are expected to be key=value.
log_event() {
    local event=$1
    shift
    printf 'build_event event=%s target=%s build_id=%s elapsed_seconds=%s' \
        "${event}" "${target_name}" "${build_id}" "${SECONDS}"
    local field
    for field in "$@"; do
        printf ' %s' "${field}"
    done
    printf '\n'
}

# Strip anything secret-bearing out of text captured from another command
# before it is logged: URL userinfo, and query strings.
redact_secrets() {
    sed -E -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/[:space:]]*@#\1REDACTED@#g' \
        -e 's#\?[^[:space:]]*#?REDACTED#g'
}

die() {
    log_event build_failed "detail=\"$*\""
    echo "$0: $*" >&2
    exit 1
}

# A staged set that may not be published. Every rejection is reported the same
# way, so a CI log can be filtered on one event.
reject() {
    log_event validation_failed "detail=\"$*\""
    die "$*"
}

# Remove only this invocation's own scratch: the part-downloaded tarball, the
# staging directory, and the container and image this invocation created.
# Idempotent, because the INT and TERM handlers fall through to the EXIT
# handler.
#
# A <staging>.previous directory is never touched here. On the fallback path
# it is the only remaining copy of the last complete output whenever rollback
# has failed, so removing it would destroy the recovery data.
#
# The container and image are named after build_id, so nothing belonging to a
# concurrent build or to an unrelated project can be removed here.
cleanup() {
    local removed_download=no removed_staging=no
    local removed_container=no removed_image=no
    if [[ -n ${download_tmp} && -e ${download_tmp} ]]; then
        rm -f "${download_tmp}"
        removed_download=yes
    fi
    if [[ -n ${staging_dir} && -e ${staging_dir} ]]; then
        rm -rf "${staging_dir}"
        removed_staging=yes
    fi
    if [[ -n ${deps_container} ]]; then
        "${PODMAN}" rm -f "${deps_container}" >/dev/null 2>&1 || true
        removed_container=yes
        deps_container=
    fi
    if [[ -n ${temp_image} ]]; then
        "${PODMAN}" rmi -f "${temp_image}" >/dev/null 2>&1 || true
        removed_image=yes
        temp_image=
    fi
    if [[ ${removed_download} == yes || ${removed_staging} == yes ||
        ${removed_container} == yes || ${removed_image} == yes ]]; then
        log_event cleanup "removed_download=${removed_download}" \
            "removed_staging=${removed_staging}" \
            "removed_container=${removed_container}" \
            "removed_image=${removed_image}"
    fi
    download_tmp=
    staging_dir=
    return 0
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Resolve the dist tag this target must produce. An unrecognized target is an
# error rather than a guess, because publishing a package built for the wrong
# distribution under a target's name is worse than not publishing at all.
resolve_expected_dist() {
    local default_dist=
    case ${target_name} in
    fedora-43) default_dist=fc43 ;;
    rocky-10) default_dist=el10 ;;
    esac
    : "${EXPECTED_DIST:=${default_dist}}"
    [[ -n ${EXPECTED_DIST} ]] ||
        die "unknown target '${target_name}'; set EXPECTED_DIST to the expected dist tag"
    log_event target_resolved "dist=${EXPECTED_DIST}" "arch=${EXPECTED_ARCH}"
}

# The tarball pinned above and the commit the spec packages must be the same
# commit. If they drift apart the build would silently produce a package whose
# version claims one snapshot and whose sources are another, so this is
# checked before anything is downloaded or built.
check_spec_commit() {
    [[ -f ${spec_file} ]] || die "the spec file ${spec_file} does not exist"
    local spec_commit
    spec_commit=$(sed -n \
        's/^%global[[:space:]]\+commit[[:space:]]\+\([0-9a-fA-F]\{40\}\).*/\1/p' \
        "${spec_file}" | head -1)
    [[ -n ${spec_commit} ]] ||
        die "could not read '%global commit' from ${spec_file}"
    [[ ${spec_commit} == "${commit}" ]] ||
        die "the spec packages commit ${spec_commit} but this script pins ${commit}; update both together"
    log_event spec_commit_ok "commit=${short_commit}"
}

# Take the activity lock shared, for the lifetime of this process. Any number
# of builds may hold it at once; scripts/clean.sh waits for all of them.
acquire_activity_lock() {
    mkdir -p "${LOCK_DIR}"
    exec {activity_fd}>"${LOCK_DIR}/activity.lock"
    "${FLOCK}" -s "${activity_fd}"
    log_event activity_lock_acquired
}

# True when $1 exists and matches the expected checksum.
checksum_matches() {
    [[ -f $1 ]] || return 1
    echo "${tarball_sha256}  $1" | "${SHA256SUM}" -c --status -
}

# Fetch the upstream tarball into the shared cache, leaving a file at
# "${cache_dir}/${tarball}" whose checksum matches ${tarball_sha256}.
#
# The cache is shared between the two targets and between concurrent runs:
# the Makefile's .NOTPARALLEL only orders targets within a single make
# process, so two make invocations (or two direct calls to this script) can
# reach here at once. Downloading to a per-invocation temporary file and
# publishing it with a single rename keeps that safe — concurrent runs
# cannot truncate each other's download or expose a partial file under the
# final name. Reuse is gated on the checksum rather than on mere presence,
# so a file left behind by an interrupted run is re-fetched instead of
# failing the build.
fetch_tarball() {
    mkdir -p "${cache_dir}"

    if checksum_matches "${cache_dir}/${tarball}"; then
        log_event cache_hit "tarball=${tarball}"
        return
    fi
    log_event cache_miss "tarball=${tarball}"

    # The URL is never logged: it is overridable and may carry userinfo or a
    # query token. The filename is enough to identify what is being fetched.
    log_event download_start "tarball=${tarball}"
    download_tmp=$(mktemp "${cache_dir}/${tarball}.XXXXXX")
    local curl_stderr
    if ! curl_stderr=$("${CURL}" -fsSL -o "${download_tmp}" "${tarball_url}" 2>&1 >/dev/null); then
        die "download of ${tarball} failed: $(redact_secrets <<<"${curl_stderr}" | tr '\n' ' ')"
    fi
    if ! checksum_matches "${download_tmp}"; then
        log_event checksum_failed "tarball=${tarball}"
        die "checksum mismatch for downloaded ${tarball}"
    fi
    mv -f "${download_tmp}" "${cache_dir}/${tarball}"
    download_tmp=
    log_event cache_published "tarball=${tarball}"
}

# The read-only mounts shared by every phase: the spec, the packaging sources,
# the patches and the verified tarball. The RPM's SOURCES are exactly the
# tarball plus every file in packaging/ and patches/.
source_mounts() {
    printf '%s\n' \
        -v "${spec_file}:/work/${spec_name}:ro,z" \
        -v "${PACKAGING_DIR}:/work/packaging:ro,z" \
        -v "${PATCHES_DIR}:/work/patches:ro,z" \
        -v "${cache_dir}/${tarball}:/work/${tarball}:ro,z"
}

# Phase A. Install the toolchain and the spec's declared build dependencies in
# a named container, then commit it. This is the only phase that may reach the
# network, and it is deliberately not --rm: its filesystem is the input to the
# two offline phases that follow.
build_phase_deps() {
    local -a mounts
    mapfile -t mounts < <(source_mounts)

    log_event phase_deps_start "container=${deps_container}"
    # The single-quoted script below is expanded by the container's shell,
    # not this one, so its ${...} references must survive unexpanded.
    # shellcheck disable=SC2016
    if ! "${PODMAN}" run --name "${deps_container}" \
        "${mounts[@]}" \
        "${image}" \
        bash -c '
            set -euo pipefail
            dnf -y install rpm-build dnf-plugins-core
            # Rocky keeps meson in CRB, which is shipped disabled. The two
            # spellings cover dnf4 and dnf5.
            if grep -q "^ID=\"\?rocky\"\?$" /etc/os-release; then
                dnf -y config-manager --set-enabled crb ||
                    dnf -y config-manager setopt crb.enabled=1
            fi
            dnf -y builddep /work/'"${spec_name}"'
        '; then
        log_event phase_deps_failed
        die "installing build dependencies for ${target_name} failed; see the output above"
    fi

    if ! "${PODMAN}" commit "${deps_container}" "${temp_image}"; then
        log_event commit_failed
        die "committing the build environment for ${target_name} failed"
    fi
    log_event phase_deps_ok "image=${temp_image}"
}

# Phase B. Build the packages offline from the committed environment, then
# describe what was built in /out/manifest.tsv and refuse payload paths that
# escape the permitted roots.
build_phase_rpms() {
    local -a mounts
    mapfile -t mounts < <(source_mounts)

    log_event phase_build_start
    # shellcheck disable=SC2016
    if ! "${PODMAN}" run --rm --network=none \
        "${mounts[@]}" \
        -v "${staging_dir}:/out:z" \
        "${temp_image}" \
        bash -c '
            set -euo pipefail
            topdir=/work/rpmbuild
            mkdir -p "${topdir}/SOURCES"
            # mktemp leaves the cached tarball 0600; give the copy that goes
            # into the source RPM the conventional mode.
            install -m 0644 /work/'"${tarball}"' "${topdir}/SOURCES/"
            cp /work/packaging/* "${topdir}/SOURCES/"
            cp /work/patches/* "${topdir}/SOURCES/"

            # Never pipe rpmbuild into head: SIGPIPE kills the build. Log to a
            # file and inspect the file afterwards.
            if ! rpmbuild --define "_topdir ${topdir}" -ba /work/'"${spec_name}"' \
                >"${topdir}/rpmbuild.log" 2>&1; then
                cat "${topdir}/rpmbuild.log"
                exit 1
            fi
            tail -n 40 "${topdir}/rpmbuild.log"

            mkdir -p /out/srpm
            cp "${topdir}"/RPMS/*/*.rpm /out/
            cp "${topdir}"/SRPMS/*.src.rpm /out/srpm/

            # A binary package may only own paths under /usr or /etc. Anything
            # under /usr/local, anything under /usr/src other than the
            # debugsource tree, and any path that leaked the buildroot or the
            # build topdir is a packaging defect, not a publishable package.
            for rpm in /out/*.rpm; do
                offending=$(rpm -qpl "${rpm}" | awk -v topdir="${topdir}" "
                    /BUILDROOT/ { print; next }
                    index(\$0, topdir) == 1 { print; next }
                    /^\/usr\/local(\/|\$)/ { print; next }
                    /^\/usr\/src\/debug(\/|\$)/ { next }
                    /^\/usr\/src(\/|\$)/ { print; next }
                    /^\/usr(\/|\$)/ { next }
                    /^\/etc(\/|\$)/ { next }
                    { print }
                ")
                if [[ -n ${offending} ]]; then
                    echo "unexpected payload paths in ${rpm}:" >&2
                    echo "${offending}" >&2
                    exit 1
                fi
            done

            manifest=/out/manifest.tsv
            : >"${manifest}"
            for rpm in /out/*.rpm /out/srpm/*.src.rpm; do
                rel=${rpm#/out/}
                fields=$(rpm -qp --qf \
                    "%{NAME}\t%{EPOCH}\t%{VERSION}\t%{RELEASE}\t%{ARCH}" "${rpm}")
                sum=$(sha256sum "${rpm}" | cut -d" " -f1)
                printf "%s\t%s\t%s\n" "${rel}" "${fields}" "${sum}" >>"${manifest}"
            done
            cat "${manifest}"
        '; then
        log_event phase_build_failed
        die "the container build for ${target_name} failed; see the output above"
    fi
    log_event phase_build_ok
}

# Phase C. Rebuild the SRPM in a clean topdir, offline, and insist that it
# yields the same package file names. A source RPM that cannot reproduce its
# own binaries is not a publishable source RPM.
build_phase_srpm_rebuild() {
    log_event phase_rebuild_start
    # shellcheck disable=SC2016
    if ! "${PODMAN}" run --rm --network=none \
        -v "${staging_dir}:/out:ro,z" \
        "${temp_image}" \
        bash -c '
            set -euo pipefail
            topdir=/work/rebuild
            rm -rf "${topdir}"
            mkdir -p "${topdir}"
            if ! rpmbuild --define "_topdir ${topdir}" --rebuild /out/srpm/*.src.rpm \
                >"${topdir}/rebuild.log" 2>&1; then
                cat "${topdir}/rebuild.log"
                exit 1
            fi
            tail -n 40 "${topdir}/rebuild.log"

            rebuilt=$(cd "${topdir}/RPMS" && find . -name "*.rpm" -printf "%f\n" | sort)
            original=$(cd /out && find . -maxdepth 1 -name "*.rpm" -printf "%f\n" | sort)
            if [[ ${rebuilt} != "${original}" ]]; then
                echo "the SRPM rebuild produced a different package set:" >&2
                echo "  original: ${original}" >&2
                echo "  rebuilt:  ${rebuilt}" >&2
                exit 1
            fi
        '; then
        log_event phase_rebuild_failed
        die "the SRPM rebuild for ${target_name} failed; see the output above"
    fi
    log_event phase_rebuild_ok
}

# Run the three phases against a staging directory owned by this invocation.
# The published directory is deliberately not mounted: nothing outside this
# script ever sees a half-populated output directory.
build_in_container() {
    mkdir -p "${STAGING_ROOT}"
    staging_dir=$(mktemp -d "${STAGING_ROOT}/${target_name}.XXXXXX")
    log_event staging_created

    deps_container="guildmaster-build-${build_id}"
    temp_image="localhost/guildmaster-build:${build_id}"

    build_phase_deps
    build_phase_rpms
    build_phase_srpm_rebuild

    # Success path: drop this invocation's container and image now rather than
    # leaving them for the exit trap, so a long publication step does not hold
    # a gigabyte of layers open.
    "${PODMAN}" rm -f "${deps_container}" >/dev/null 2>&1 || true
    deps_container=
    "${PODMAN}" rmi -f "${temp_image}" >/dev/null 2>&1 || true
    temp_image=
    log_event containers_removed
}

# --- publication validation -------------------------------------------------

# Everything the staging directory is allowed to contain, as paths relative to
# it. Set by validate_staging once the base package has named the version.
expected_entries=()
expected_rpms=()

# Check that manifest.tsv describes exactly the packages that were built,
# with no epoch and a checksum that matches each file's bytes.
validate_manifest() {
    local manifest="${staging_dir}/manifest.tsv"
    local lineno=0 line rel name epoch version release arch sum extra
    local -a listed=()

    [[ -s ${manifest} ]] || reject "manifest.tsv is empty"

    while IFS= read -r line || [[ -n ${line} ]]; do
        lineno=$((lineno + 1))
        IFS=$'\t' read -r rel name epoch version release arch sum extra <<<"${line}"
        [[ -z ${extra} ]] ||
            reject "manifest.tsv line ${lineno} has more than seven fields"
        [[ -n ${sum} ]] ||
            reject "manifest.tsv line ${lineno} has fewer than seven fields"
        [[ ${epoch} == '(none)' ]] ||
            reject "manifest.tsv line ${lineno} records epoch '${epoch}'; this package has no epoch"
        [[ -f ${staging_dir}/${rel} ]] ||
            reject "manifest.tsv lists '${rel}', which the build did not produce"

        local expected_name
        if [[ ${rel} == srpm/* ]]; then
            expected_name="${name}-${version}-${release}.src.rpm"
        else
            expected_name="${name}-${version}-${release}.${arch}.rpm"
        fi
        [[ $(basename "${rel}") == "${expected_name}" ]] ||
            reject "manifest.tsv line ${lineno} describes ${expected_name} but names '${rel}'"

        echo "${sum}  ${staging_dir}/${rel}" | "${SHA256SUM}" -c --status - ||
            reject "manifest.tsv line ${lineno} records a sha256 that does not match '${rel}'"

        listed+=("${rel}")
    done <"${manifest}"

    local listed_sorted unique_sorted expected_sorted
    listed_sorted=$(printf '%s\n' "${listed[@]}" | LC_ALL=C sort)
    unique_sorted=$(printf '%s\n' "${listed_sorted}" | LC_ALL=C sort -u)
    [[ ${listed_sorted} == "${unique_sorted}" ]] ||
        reject "manifest.tsv lists the same package more than once"

    expected_sorted=$(printf '%s\n' "${expected_rpms[@]}" | LC_ALL=C sort)
    if [[ ${listed_sorted} != "${expected_sorted}" ]]; then
        local unlisted
        unlisted=$(LC_ALL=C comm -13 <(printf '%s\n' "${listed_sorted}") \
            <(printf '%s\n' "${expected_sorted}") | tr '\n' ' ')
        reject "manifest.tsv does not describe every package; unlisted: ${unlisted}"
    fi
}

# Refuse to publish anything but exactly the expected set. A build that
# produced only some of its packages, or produced something extra, must leave
# the previous output in place rather than replace it with something the tmt
# plans and the release job would then treat as the build's full result.
validate_staging() {
    local -a entries=()
    mapfile -t entries < <(find "${staging_dir}" -mindepth 1 -printf '%P\n' |
        LC_ALL=C sort)

    if [[ ${#entries[@]} -eq 0 ]]; then
        log_event validation_failed 'detail="the build produced no output"'
        die "the build for ${target_name} produced no output"
    fi

    local -a devel=()
    mapfile -t devel < <(printf '%s\n' "${entries[@]}" |
        grep -E '^guildmaster-devel-.*\.rpm$' || true)
    if [[ ${#devel[@]} -gt 0 ]]; then
        log_event validation_failed 'detail="a -devel subpackage was produced"'
        die "the build for ${target_name} produced a -devel subpackage (${devel[0]}); this package ships none"
    fi

    local -a base=()
    mapfile -t base < <(printf '%s\n' "${entries[@]}" |
        grep -E '^guildmaster-[^/]*\.rpm$' |
        grep -Ev '^guildmaster-(debuginfo|debugsource)-' || true)
    if [[ ${#base[@]} -eq 0 ]]; then
        log_event validation_failed 'detail="no binary package"'
        die "the build for ${target_name} produced no binary package"
    fi
    if [[ ${#base[@]} -gt 1 ]]; then
        log_event validation_failed "detail=\"${#base[@]} binary packages\""
        die "the build for ${target_name} produced more than one binary package: ${base[*]}"
    fi

    # guildmaster-<version>-<release>.<arch>.rpm, where <release> carries the
    # dist tag. The version contains a caret, so it is split off positionally
    # rather than matched with a pattern.
    local stem=${base[0]%.rpm}
    local arch=${stem##*.}
    local name_evr=${stem%.*}
    local release=${name_evr##*-}
    local version=${name_evr%-*}
    version=${version#guildmaster-}
    local dist=${release##*.}

    if [[ ${arch} == noarch ]]; then
        log_event validation_failed "arch=${arch}"
        die "the build for ${target_name} produced a noarch package; guildmaster is native"
    fi
    if [[ ${arch} != "${EXPECTED_ARCH}" ]]; then
        log_event validation_failed "arch=${arch}"
        die "the build for ${target_name} produced ${arch} packages, expected ${EXPECTED_ARCH}"
    fi
    if [[ ${dist} != "${EXPECTED_DIST}" ]]; then
        log_event validation_failed "dist=${dist}"
        die "the build for ${target_name} carries dist tag .${dist}, expected .${EXPECTED_DIST}"
    fi
    if [[ ${version} != *"git${short_commit}"* ]]; then
        log_event validation_failed "version=${version}"
        die "the build for ${target_name} has version ${version}, which does not name commit ${short_commit}"
    fi

    expected_rpms=(
        "guildmaster-${version}-${release}.${arch}.rpm"
        "guildmaster-debuginfo-${version}-${release}.${arch}.rpm"
        "guildmaster-debugsource-${version}-${release}.${arch}.rpm"
        "srpm/guildmaster-${version}-${release}.src.rpm"
    )
    expected_entries=("${expected_rpms[@]}" manifest.tsv srpm)

    local actual_sorted expected_sorted missing unexpected
    actual_sorted=$(printf '%s\n' "${entries[@]}" | LC_ALL=C sort)
    expected_sorted=$(printf '%s\n' "${expected_entries[@]}" | LC_ALL=C sort)
    if [[ ${actual_sorted} != "${expected_sorted}" ]]; then
        missing=$(LC_ALL=C comm -13 <(printf '%s\n' "${actual_sorted}") \
            <(printf '%s\n' "${expected_sorted}") | tr '\n' ' ')
        unexpected=$(LC_ALL=C comm -23 <(printf '%s\n' "${actual_sorted}") \
            <(printf '%s\n' "${expected_sorted}") | tr '\n' ' ')
        log_event validation_failed "detail=\"missing: ${missing:-none}; unexpected: ${unexpected:-none}\""
        die "incomplete or unexpected build for ${target_name}; missing: ${missing:-none}; unexpected: ${unexpected:-none}"
    fi

    validate_manifest

    log_event validation_ok "version=${version}" "release=${release}" \
        "arch=${arch}" "packages=${#expected_rpms[@]}"
}

# Replace the published directory with the staged one under an exclusive
# per-target lock.
#
# `mv -T --exchange` (renameat2 RENAME_EXCHANGE) swaps the two directories in
# one atomic step, so a reader of <outdir> sees either the whole previous set
# or the whole new one. Hosts without it — coreutils older than 9.5, or a
# filesystem that does not implement the call — take the fallback path, which
# is NOT atomic: it moves the previous output aside and then moves staging
# into place, so <outdir> is briefly absent during a normal swap. No partial
# or mixed set is ever visible either way.
#
# If the fallback's promotion fails, the previous output is rolled back into
# place and the build exits non-zero. If the rollback itself fails, the build
# still exits non-zero and the previous complete output is left at
# <staging>.previous, which cleanup deliberately does not remove.
publish_staging() {
    local published_fd previous fallback_reason
    mkdir -p "${LOCK_DIR}" "$(dirname "${outdir_path}")"
    exec {published_fd}>"${LOCK_DIR}/publish-${target_name}.lock"
    "${FLOCK}" -x "${published_fd}"
    log_event publication_lock_acquired

    if [[ ! -e ${outdir_path} ]]; then
        # First publication: a plain rename into a free name is atomic.
        mv -T "${staging_dir}" "${outdir_path}"
        log_event published mode=first
        exec {published_fd}>&-
        return
    fi

    if [[ ${PUBLISH_EXCHANGE} != never ]] &&
        mv -T --exchange "${staging_dir}" "${outdir_path}" 2>/dev/null; then
        # staging_dir now holds the superseded set; cleanup drops it.
        log_event published mode=exchange
        exec {published_fd}>&-
        return
    fi

    if [[ ${PUBLISH_EXCHANGE} == never ]]; then
        fallback_reason=exchange_disabled
    else
        fallback_reason=exchange_unsupported
    fi

    previous="${staging_dir}.previous"
    mv -T "${outdir_path}" "${previous}" ||
        die "could not move the previous output of ${target_name} aside"

    if "${PUBLISH_MV}" -T "${staging_dir}" "${outdir_path}"; then
        rm -rf "${previous}"
        log_event published mode=fallback "fallback_reason=${fallback_reason}"
        exec {published_fd}>&-
        return
    fi

    log_event publish_fallback_failed "fallback_reason=${fallback_reason}"
    log_event rollback_start "recoverable_path=${previous}"
    if "${PUBLISH_MV}" -T "${previous}" "${outdir_path}"; then
        log_event rollback_ok
        exec {published_fd}>&-
        die "publication of ${target_name} failed; the previous complete output has been restored"
    fi

    log_event rollback_failed "recoverable_path=${previous}"
    exec {published_fd}>&-
    die "publication of ${target_name} failed and the rollback failed; the previous complete output is preserved at ${previous}"
}

# Test-only seam. Announces that this build has staged and validated a
# complete set and is about to contend for the publication lock, then blocks
# until released. It is inert unless PREPUBLISH_ANNOUNCE_FIFO is set, which
# no real build sets, and it changes nothing else: the activity lock is still
# held and the staged output is still unpublished while it waits. It exists
# so scripts/tests/test-build-rpm.sh can hold two builds of the same target
# at exactly this point and then release them into the publication lock
# together.
prepublish_barrier() {
    [[ -n ${PREPUBLISH_ANNOUNCE_FIFO:-} ]] || return 0
    echo staged >"${PREPUBLISH_ANNOUNCE_FIFO}"
    [[ -n ${PREPUBLISH_WAIT_FIFO:-} ]] || return 0
    read -r _ <"${PREPUBLISH_WAIT_FIFO}"
}

resolve_expected_dist
check_spec_commit
acquire_activity_lock
fetch_tarball
build_in_container
validate_staging
prepublish_barrier
publish_staging

log_event build_complete
echo "RPMs written to ${outdir}"
