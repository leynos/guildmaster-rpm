#!/usr/bin/env bash
# Validate the complete set of tested packages and lay out the release assets.
#
# Usage: scripts/assemble-release.sh <tag> <artefact-dir> <asset-dir>
#   <tag>           the release tag, for example v0.1-20251202git463382b-1
#   <artefact-dir>  holds one directory per target (rocky-10, fedora-43), each
#                   a build-rpm.sh output directory with its manifest.tsv,
#                   exactly as the test jobs received and tested it
#   <asset-dir>     is created, and must not already exist
#
# Nothing is built here. The publication job runs this on the artefacts that
# passed the container and guest tiers, and uploads what it writes.
#
# It refuses to produce anything unless, for every target in TARGETS:
#   - the directory and its manifest exist;
#   - the manifest lists exactly the expected four packages for that target's
#     dist tag and architecture, with no epoch, and nothing else is present;
#   - every file matches the checksum in its manifest;
#   - the version and release agree with the tag and with guildmaster.spec;
# and unless no asset name occurs twice across targets. Files are copied with
# "cp -n" semantics checked explicitly: a name collision is an error, never an
# overwrite.
#
# Asset names
#   GitHub rewrites characters it does not accept in an asset name, and the
#   caret in the RPM version is one of them: it becomes a full stop. The
#   rewrite is done here instead, so that SHA256SUMS names the files exactly as
#   a user will download them. The file name is not part of an RPM's identity;
#   the packages still report their real version.
#
# Outputs in <asset-dir>: the RPMs, SHA256SUMS (release-relative names) and
# release-notes.md.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <tag> <artefact-dir> <asset-dir>" >&2
    exit 2
fi
tag=$1
artefact_dir=$2
asset_dir=$3

repo_root=$(cd "$(dirname "$0")/.." && pwd)
: "${SHA256SUM:=sha256sum}"
: "${SPEC:=${repo_root}/guildmaster.spec}"
: "${TARGETS:=rocky-10 fedora-43}"
: "${ARCH:=x86_64}"
: "${SOURCE_COMMIT:=$(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo unknown)}"
: "${EVIDENCE_DIR:=}"

die() {
    echo "assemble-release: $*" >&2
    exit 1
}

dist_for() {
    case $1 in
    rocky-10) echo el10 ;;
    fedora-43) echo fc43 ;;
    *) die "unknown target $1" ;;
    esac
}

spec_global() {
    sed -n "s/^%global[[:space:]]\+$1[[:space:]]\+//p" "${SPEC}" | head -n 1
}

# The version and release the spec will have produced.
commit=$(spec_global commit)
snapshot=$(spec_global snapshotdate)
upstream=$(spec_global upstream_version)
release=$(sed -n 's/^Release:[[:space:]]*\([0-9]\+\)%{?dist}$/\1/p' "${SPEC}")
[[ -n ${commit} && -n ${snapshot} && -n ${upstream} && -n ${release} ]] ||
    die "could not read the version from ${SPEC}"
version="${upstream}^${snapshot}git${commit:0:7}"

# Git does not allow a caret in a tag; the tag uses a hyphen in its place.
expected_tag="v${version/^/-}-${release}"
[[ ${tag} == "${expected_tag}" ]] ||
    die "tag ${tag} does not match the spec, which describes ${expected_tag}"

[[ ! -e ${asset_dir} ]] || die "${asset_dir} already exists"
staging=$(mktemp -d "$(dirname "${asset_dir}")/.assets.XXXXXX")
trap 'rm -rf "${staging}"' EXIT

for target in ${TARGETS}; do
    dist=$(dist_for "${target}")
    dir=${artefact_dir}/${target}
    manifest=${dir}/manifest.tsv
    [[ -d ${dir} ]] || die "${target}: no artefact directory ${dir}"
    [[ -f ${manifest} ]] || die "${target}: no manifest.tsv"

    nvr="${version}-${release}.${dist}"
    expected=$(printf '%s\n' \
        "guildmaster-${nvr}.${ARCH}.rpm" \
        "guildmaster-debuginfo-${nvr}.${ARCH}.rpm" \
        "guildmaster-debugsource-${nvr}.${ARCH}.rpm" \
        "srpm/guildmaster-${nvr}.src.rpm" | LC_ALL=C sort)
    listed=$(cut -f1 "${manifest}" | LC_ALL=C sort)
    [[ ${listed} == "${expected}" ]] ||
        die "${target}: the manifest does not list exactly the expected packages; got: $(tr '\n' ' ' <<<"${listed}")"
    present=$(cd "${dir}" && find . -type f ! -name manifest.tsv | sed 's#^\./##' | LC_ALL=C sort)
    [[ ${present} == "${expected}" ]] ||
        die "${target}: unexpected or missing files; present: $(tr '\n' ' ' <<<"${present}")"

    while IFS=$'\t' read -r filename name epoch file_version file_release arch sha256; do
        [[ ${epoch} == '(none)' ]] || die "${target}: ${filename} has epoch ${epoch}"
        [[ ${file_version} == "${version}" && ${file_release} == "${release}.${dist}" ]] ||
            die "${target}: ${filename} is ${file_version}-${file_release}, expected ${nvr}"
        case ${filename} in
        srpm/*) [[ ${arch} == src || ${arch} == "${ARCH}" ]] || die "${target}: ${filename} has arch ${arch}" ;;
        *) [[ ${arch} == "${ARCH}" ]] || die "${target}: ${filename} has arch ${arch}, expected ${ARCH}" ;;
        esac
        [[ ${name} == guildmaster* ]] || die "${target}: ${filename} is package ${name}"
        echo "${sha256}  ${dir}/${filename}" | "${SHA256SUM}" -c --status - ||
            die "${target}: ${filename} does not match its manifest checksum"

        asset=$(basename "${filename}")
        asset=${asset//^/.}
        [[ ! -e ${staging}/${asset} ]] ||
            die "asset name ${asset} occurs more than once across targets"
        cp "${dir}/${filename}" "${staging}/${asset}"
    done <"${manifest}"
done

(cd "${staging}" && "${SHA256SUM}" -- *.rpm >SHA256SUMS)

{
    echo "guildmaster ${version}-${release} for Rocky Linux 10 and Fedora 43 (${ARCH})."
    echo
    echo "- Upstream: <https://codeberg.org/amonakov/guildmaster> at commit"
    echo "  \`${commit}\` (upstream has no release tags; version ${upstream})."
    echo "- Packaging: <https://github.com/leynos/guildmaster-rpm> at commit"
    echo "  \`${SOURCE_COMMIT}\`, tag \`${tag}\`."
    echo "- Downstream patches: \`0001-add-tokens-option.patch\`, which adds"
    echo "  \`--tokens N\` for choosing the token pool capacity. Without the"
    echo "  option, behaviour is upstream's."
    echo "- Tested targets: for each distribution, the packages below passed the"
    echo "  rootless systemd container tier and the fresh-guest CUSE acceptance"
    echo "  tier (KVM guest, SELinux enforcing) before publication. These are"
    echo "  the same files that were tested; nothing was rebuilt."
    echo
    echo "## Installing"
    echo
    echo "These assets are not a DNF repository. Download, verify with"
    echo "\`sha256sum --check SHA256SUMS\`, and install with"
    echo "\`dnf install ./<package>.rpm\`. See the"
    echo "[users' guide](https://github.com/leynos/guildmaster-rpm/blob/${tag}/docs/users-guide.md)."
    echo
    echo "## Known limitations"
    echo
    echo "- The RPMs are **unsigned**. \`SHA256SUMS\` detects changed bytes; it is"
    echo "  not a signature and not an independent guarantee of authenticity."
    echo "- x86_64 only."
    echo "- The \`cuse\` kernel module must be installed for the running kernel"
    echo "  (\`kernel-modules-extra\` on both distributions)."
    echo "- Installing guildmaster does not by itself constrain Cargo or any"
    echo "  other tool, and a token count is not a CPU-thread or memory limit."
    echo "- Asset file names have the version's caret replaced by a full stop,"
    echo "  because GitHub does not accept a caret in asset names. The packages"
    echo "  themselves report version \`${version}\`."
    echo
    echo "## Checksums"
    echo
    echo '```plaintext'
    cat "${staging}/SHA256SUMS"
    echo '```'
    if [[ -n ${EVIDENCE_DIR} && -d ${EVIDENCE_DIR} ]]; then
        echo
        echo "## Acceptance evidence"
        local_file=
        for local_file in "${EVIDENCE_DIR}"/*.txt; do
            [[ -f ${local_file} ]] || continue
            echo
            echo "### $(basename "${local_file}")"
            echo
            echo '```plaintext'
            cat "${local_file}"
            echo '```'
        done
    fi
} >"${staging}/release-notes.md"

mv -T "${staging}" "${asset_dir}"
trap - EXIT
echo "assemble-release: wrote $(find "${asset_dir}" -name '*.rpm' | wc -l) packages to ${asset_dir}"
