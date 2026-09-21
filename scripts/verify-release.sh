#!/usr/bin/env bash
# Download a published release and prepare it for post-publication testing.
#
# Usage: scripts/verify-release.sh <tag> <directory>
#
# Downloads every asset of the public release <tag> into
# <directory>/assets, checks them against the release's own SHA256SUMS, checks
# each package's RPM metadata against the tag, and lays the packages out as
# <directory>/<target>/ with a manifest.tsv, which is the shape
# scripts/cuse-guest.sh and scripts/systemd-fixture.sh install from. The
# point is to test the bytes the public can download, not the local dist/.
#
# SHA256SUMS comes from the same release as the packages. Passing this check
# shows that the downloads are intact and are the published bytes; it is not
# independent proof of who built them. The packages are unsigned.
#
# Needs gh and rpm on the host. GH and RPM are seams for tests.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <tag> <directory>" >&2
    exit 2
fi
tag=$1
out=$2

: "${GH:=gh}"
: "${RPM:=rpm}"
: "${SHA256SUM:=sha256sum}"
: "${REPOSITORY:=leynos/guildmaster-rpm}"
: "${TARGETS:=rocky-10 fedora-43}"
: "${ARCH:=x86_64}"

die() {
    echo "verify-release: $*" >&2
    exit 1
}

[[ ! -e ${out} ]] || die "${out} already exists"
[[ ${tag} =~ ^v([0-9][^-]*)-([0-9]{8}git[0-9a-f]{7})-([0-9]+)$ ]] ||
    die "tag ${tag} is not of the form v<version>-<date>git<commit>-<release>"
version="${BASH_REMATCH[1]}^${BASH_REMATCH[2]}"
release=${BASH_REMATCH[3]}

mkdir -p "${out}/assets"
"${GH}" release download "${tag}" --repo "${REPOSITORY}" --dir "${out}/assets" ||
    die "could not download release ${tag} from ${REPOSITORY}"
[[ -f ${out}/assets/SHA256SUMS ]] || die 'the release has no SHA256SUMS'

(cd "${out}/assets" && "${SHA256SUM}" --check --strict SHA256SUMS) ||
    die 'a downloaded asset does not match SHA256SUMS'
listed=$(awk '{ print $2 }' "${out}/assets/SHA256SUMS" | LC_ALL=C sort)
present=$(cd "${out}/assets" && find . -maxdepth 1 -name '*.rpm' | sed 's#^\./##' | LC_ALL=C sort)
[[ ${listed} == "${present}" ]] ||
    die 'SHA256SUMS does not list exactly the RPM assets of the release'

for target in ${TARGETS}; do
    case ${target} in
    rocky-10) dist=el10 ;;
    fedora-43) dist=fc43 ;;
    *) die "unknown target ${target}" ;;
    esac
    mkdir -p "${out}/${target}/srpm"
    count=0
    for asset in "${out}"/assets/guildmaster*."${dist}".*.rpm; do
        [[ -f ${asset} ]] || continue
        IFS=$'\t' read -r name epoch file_version file_release arch < <(
            "${RPM}" -qp --nosignature \
                --qf '%{NAME}\t%{EPOCH}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\n' "${asset}"
        )
        [[ ${file_version} == "${version}" && ${file_release} == "${release}.${dist}" ]] ||
            die "$(basename "${asset}") is ${file_version}-${file_release}, not ${version}-${release}.${dist}"
        [[ ${epoch} == '(none)' ]] || die "$(basename "${asset}") has an epoch"
        [[ ${arch} == "${ARCH}" ]] || die "$(basename "${asset}") has arch ${arch}"
        case ${asset} in
        *.src.rpm) relative=srpm/$(basename "${asset}") ;;
        *) relative=$(basename "${asset}") ;;
        esac
        cp "${asset}" "${out}/${target}/${relative}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${relative}" "${name}" "${epoch}" \
            "${file_version}" "${file_release}" "${arch}" \
            "$("${SHA256SUM}" <"${asset}" | cut -d' ' -f1)" >>"${out}/${target}/manifest.tsv"
        count=$((count + 1))
    done
    [[ ${count} -eq 4 ]] || die "${target}: expected 4 packages in the release, found ${count}"
    echo "verify-release: ${target}: ${count} packages verified"
done
echo "verify-release: release ${tag} verified in ${out}"
