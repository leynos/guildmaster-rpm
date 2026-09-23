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
# The output directory is replaced whole by a rename, and the activity lock
# is held shared so that "make clean" cannot run underneath the build.
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
staging=

cleanup() {
    if [[ -n ${staging} && -e ${staging} ]]; then
        rm -rf "${staging}"
    fi
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

mkdir -p "${LOCK_DIR}" "${out_root}"
exec {activity_fd}>"${LOCK_DIR}/activity.lock"
"${FLOCK}" -s "${activity_fd}"

srpm=$(find "${DIST_DIR}/${target}/srpm" -maxdepth 1 -name 'guildmaster-*.src.rpm' 2>/dev/null)
[[ -n ${srpm} && $(wc -l <<<"${srpm}") -eq 1 ]] || {
    echo "$0: expected exactly one source RPM in ${DIST_DIR}/${target}/srpm; run make rpm-${target}" >&2
    exit 1
}

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

rm -rf "${out_dir}.old"
if [[ -e ${out_dir} ]]; then
    mv -T "${out_dir}" "${out_dir}.old"
fi
mv -T "${staging}" "${out_dir}"
staging=
rm -rf "${out_dir}.old"
ls -l "${out_dir}"
