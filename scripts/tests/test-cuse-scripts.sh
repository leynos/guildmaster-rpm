#!/usr/bin/env bash
# Offline tests for scripts/cuse-image.sh and scripts/cuse-guest.sh.
#
# No network, no libvirt and no tmt: curl, tmt, virsh and qemu-img are stubs
# that record their calls and answer from a per-test scenario directory.
# These are executed script tests of the wrappers' own logic: cache safety,
# selection and verification of inputs, and ownership of cleanup. Whether a
# real guest boots is the business of virt-preflight.sh and "make test-cuse".
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
image_script=${repo_root}/scripts/cuse-image.sh
guest_script=${repo_root}/scripts/cuse-guest.sh

scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT

passed=0
failed=0
current=

# ok <message>: record a passing check for the current test.
ok() {
    passed=$((passed + 1))
    echo "ok: ${current}: $*"
}

# not_ok <message>: record a failing check for the current test.
not_ok() {
    failed=$((failed + 1))
    echo "FAIL: ${current}: $*" >&2
}

# assert_status <actual> <expected>: pass or fail on whether the two exit
# statuses match.
assert_status() {
    if [[ $1 -eq $2 ]]; then ok "exit status $2"; else not_ok "exit status $1, expected $2"; fi
}

# assert_contains <file> <needle> <message>: pass when <file> contains
# <needle>; otherwise fail and dump the file for diagnosis.
assert_contains() {
    if grep -qF -- "$2" "$1"; then ok "$3"; else
        not_ok "$3 (no '$2' in $1)"
        sed 's/^/    | /' "$1" >&2
    fi
}

# assert_lacks <file> <needle> <message>: pass when <file> does not contain
# <needle>.
assert_lacks() {
    if grep -qF -- "$2" "$1"; then not_ok "$3 (found '$2' in $1)"; else ok "$3"; fi
}

stub_dir=${scratch}/stubs
mkdir -p "${stub_dir}"

# curl stub: "downloads" ${SCENARIO}/remote to the -o argument.
cat >"${stub_dir}/curl" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${SCENARIO}/curl.log"
while [[ $# -gt 0 ]]; do
    if [[ $1 == -o ]]; then
        out=$2
        shift
    fi
    shift
done
if [[ -f ${SCENARIO}/curl_fails ]]; then
    echo 'partial' >"${out}"
    echo 'curl: (22) error fetching https://user:hunter2@example.invalid/image?token=s3cret' >&2
    exit 22
fi
cp "${SCENARIO}/remote" "${out}"
STUB

# tmt stub: records calls; on the provisioning call writes the guest record
# tmt would; on the execute call writes the guest facts the preflight test
# would.
cat >"${stub_dir}/tmt" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ $1 == --version ]]; then
    echo 'tmt version: 0.0.0-stub'
    exit 0
fi
printf '%s\n' "$*" >>"${SCENARIO}/tmt.log"
run_id=$(sed -n 's/.*--id \([^ ]*\).*/\1/p' <<<"$*")
plan_dir=${TMT_WORKDIR_ROOT}/${run_id}/plans/cuse
case " $* " in
*' provision '*)
    [[ -f ${SCENARIO}/provision_fails ]] && exit 2
    mkdir -p "${plan_dir}/provision" "${TMT_WORKDIR_ROOT}/testcloud/instances/tmt-001-stub"
    printf 'default-0:\n  instance-name: tmt-001-stub\n' >"${plan_dir}/provision/guests.yaml"
    : >"${TMT_WORKDIR_ROOT}/testcloud/instances/tmt-001-stub/disk.qcow2"
    ;;
*' execute '*)
    ls "${plan_dir}/data/rpms" >"${SCENARIO}/staged.list"
    [[ -f ${SCENARIO}/no_facts ]] || echo 'kernel: stub' >"${plan_dir}/data/guest-facts.txt"
    [[ -f ${SCENARIO}/image_changes ]] && {
        chmod u+w "${SCENARIO}/image.qcow2"
        echo changed >>"${SCENARIO}/image.qcow2"
    }
    [[ -f ${SCENARIO}/plan_fails ]] && exit 1
    ;;
*' cleanup'*)
    [[ -f ${SCENARIO}/cleanup_fails ]] && exit 2
    ;;
esac
exit 0
STUB

cat >"${stub_dir}/qemu-img" <<'STUB'
#!/usr/bin/env bash
printf '{\n    "full-backing-filename": "%s",\n    "format": "qcow2"\n}\n' "$(cat "${SCENARIO}/backing")"
STUB

cat >"${stub_dir}/virsh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SCENARIO}/virsh.log"
case " $* " in
*' dominfo '*) exit 1 ;;
*' list '*)
    [[ -f ${SCENARIO}/virsh_list_fails ]] && exit 1
    [[ -f ${SCENARIO}/virsh_still_listed ]] && echo tmt-001-stub
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "${stub_dir}"/*

# --- cuse-image.sh -----------------------------------------------------------

# new_image_scenario <name>: a pinned image and a matching remote download;
# tests then break one thing.
new_image_scenario() {
    current=$1
    SCENARIO=${scratch}/${current}
    export SCENARIO
    mkdir -p "${SCENARIO}/cache"
    echo 'the pinned image bytes' >"${SCENARIO}/remote"
    sum=$(sha256sum <"${SCENARIO}/remote" | cut -d' ' -f1)
    printf '# comment\nrocky-10\tx86_64\timage.qcow2\t%s\thttps://user:hunter2@example.invalid/image?token=s3cret\n' \
        "${sum}" >"${SCENARIO}/images.tsv"
    : >"${SCENARIO}/curl.log"
}

# run_image [extra env assignments...]: run cuse-image.sh against the
# current scenario; output in ${SCENARIO}/stdout and .../stderr, status in
# $status.
run_image() {
    status=0
    env CURL="${stub_dir}/curl" IMAGES_TSV="${SCENARIO}/images.tsv" \
        IMAGE_CACHE_DIR="${SCENARIO}/cache" IMAGE_ARCH=x86_64 "$@" \
        "${image_script}" "${image_target:-rocky-10}" \
        >"${SCENARIO}/stdout" 2>"${SCENARIO}/stderr" || status=$?
}

new_image_scenario image_download
run_image
assert_status "${status}" 0
cached=${SCENARIO}/cache/${sum:0:16}-image.qcow2
if [[ $(cat "${SCENARIO}/stdout") == "${cached}" ]]; then ok 'prints only the cached path'; else not_ok "stdout: $(cat "${SCENARIO}/stdout")"; fi
# Mode bits, not test -w, which is always true for root.
if [[ -f ${cached} && $(stat -c '%a' "${cached}") == 444 ]]; then
    ok 'the cached image is read-only'
else not_ok "cached image missing or not mode 444: $(stat -c '%a' "${cached}" 2>&1)"; fi
if [[ $(find "${SCENARIO}/cache" -type f | wc -l) -eq 1 ]]; then ok 'no temporary file is left'; else not_ok 'stray files in the cache'; fi
assert_lacks "${SCENARIO}/stderr" 'hunter2' 'the URL credentials are never logged'
assert_lacks "${SCENARIO}/stderr" 's3cret' 'the URL token is never logged'

run_image
assert_status "${status}" 0
assert_contains "${SCENARIO}/stderr" 'event=cache_hit' 'a verified cached image is reused'
if [[ $(wc -l <"${SCENARIO}/curl.log") -eq 1 ]]; then ok 'and not downloaded again'; else not_ok 'downloaded again'; fi

new_image_scenario image_corrupt_cache
run_image
chmod u+w "${SCENARIO}/cache/${sum:0:16}-image.qcow2"
echo truncated >"${SCENARIO}/cache/${sum:0:16}-image.qcow2"
run_image
assert_status "${status}" 0
assert_contains "${SCENARIO}/stderr" 'event=cache_corrupt' 'a cached image with the wrong bytes is detected'
if sha256sum "${SCENARIO}/cache/${sum:0:16}-image.qcow2" | grep -q "^${sum}"; then ok 'and replaced by verified bytes'; else not_ok 'corrupt image still cached'; fi

new_image_scenario image_wrong_bytes
echo 'something else entirely' >"${SCENARIO}/remote"
run_image
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'event=checksum_failed' 'a download with the wrong checksum is rejected'
if [[ -z $(find "${SCENARIO}/cache" -type f) ]]; then ok 'and nothing is published or left behind'; else not_ok 'files left in the cache'; fi

new_image_scenario image_download_fails
touch "${SCENARIO}/curl_fails"
run_image
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'download of image.qcow2 failed' 'a failed download is reported'
assert_lacks "${SCENARIO}/stderr" 'hunter2' 'curl diagnostics are redacted: credentials'
assert_lacks "${SCENARIO}/stderr" 's3cret' 'curl diagnostics are redacted: token'
if [[ -z $(find "${SCENARIO}/cache" -type f) ]]; then ok 'the partial download is removed'; else not_ok 'partial download left behind'; fi

new_image_scenario image_unknown_target
image_target=debian-13 run_image
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'no image is pinned for debian-13' 'an unpinned target is refused'

new_image_scenario image_other_architecture
run_image IMAGE_ARCH=aarch64
assert_status "${status}" 1
assert_contains "${SCENARIO}/stderr" 'no image is pinned for rocky-10 on aarch64' 'architecture is part of the pin'

# --- cuse-guest.sh -----------------------------------------------------------

# new_guest_scenario <name>: a verified guest image and a valid package
# directory; tests then break one thing.
new_guest_scenario() {
    current=$1
    SCENARIO=${scratch}/${current}
    export SCENARIO
    mkdir -p "${SCENARIO}/rpms/srpm" "${SCENARIO}/work" "${SCENARIO}/cache"
    echo 'guest image' >"${SCENARIO}/image.qcow2"
    chmod 0444 "${SCENARIO}/image.qcow2"
    printf 'rocky-10\t%s\timage.qcow2\t%s\tfile:///nowhere\n' "$(uname -m)" \
        "$(sha256sum <"${SCENARIO}/image.qcow2" | cut -d' ' -f1)" >"${SCENARIO}/images.tsv"
    echo "${SCENARIO}/image.qcow2" >"${SCENARIO}/backing"
    printf '#!/bin/sh\necho "%s"\n' "${SCENARIO}/image.qcow2" >"${SCENARIO}/image-script"
    chmod +x "${SCENARIO}/image-script"
    : >"${SCENARIO}/tmt.log"
    : >"${SCENARIO}/virsh.log"
    : >"${SCENARIO}/rpms/manifest.tsv"
    local file
    for file in 'guildmaster-0.1^1-1.el10.x86_64.rpm' 'srpm/guildmaster-0.1^1-1.el10.src.rpm'; do
        echo "payload of ${file}" >"${SCENARIO}/rpms/${file}"
        printf '%s\tguildmaster\t(none)\t0.1^1\t1.el10\tx86_64\t%s\n' "${file}" \
            "$(sha256sum <"${SCENARIO}/rpms/${file}" | cut -d' ' -f1)" >>"${SCENARIO}/rpms/manifest.tsv"
    done
    echo 'not part of the build' >"${SCENARIO}/rpms/stray-file.rpm"
    # The upgrade fixture every run needs; scenarios may point elsewhere.
    mkdir -p "${SCENARIO}/default-upgrade"
    echo 'upgrade fixture' >"${SCENARIO}/default-upgrade/guildmaster-0.1^1-1.el10.upgradetest.x86_64.rpm"
}

# run_guest [extra env assignments...]: run cuse-guest.sh against the
# current scenario; output in ${SCENARIO}/out, status in $status.
run_guest() {
    status=0
    env TMT="${stub_dir}/tmt" VIRSH="${stub_dir}/virsh" QEMU_IMG="${stub_dir}/qemu-img" \
        PREFLIGHT=true IMAGE_SCRIPT="${SCENARIO}/image-script" IMAGES_TSV="${SCENARIO}/images.tsv" \
        CACHE_DIR="${SCENARIO}/cache" WORK_ROOT="${SCENARIO}/work" \
        UPGRADE_RPM_DIR="${SCENARIO}/default-upgrade" "$@" \
        "${guest_script}" rocky-10 "${SCENARIO}/rpms" >"${SCENARIO}/out" 2>&1 || status=$?
}

# run_id: the tmt run id the adapter logged for the current scenario, read
# back from its output.
run_id() {
    sed -n 's/.*run=\(gm-cuse-[^ ]*\).*/\1/p' "${SCENARIO}/out" | head -n 1
}

# assert_own_cleanup: pass when tmt was asked to clean up this run's own id.
assert_own_cleanup() {
    if grep -q -- "--id $(run_id) cleanup" "${SCENARIO}/tmt.log"; then
        ok 'tmt is asked to clean up this run id'
    else
        not_ok 'no cleanup of this run id'
    fi
}

new_guest_scenario guest_happy_path
run_guest
assert_status "${status}" 0
assert_contains "${SCENARIO}/tmt.log" 'provision --how virtual --connection session' 'the native virtual provisioner and the user session are used'
assert_contains "${SCENARIO}/tmt.log" "--image ${SCENARIO}/image.qcow2" 'the image is given by absolute path'
assert_contains "${SCENARIO}/tmt.log" '--context distro=rocky-10' 'the distro context matches the target'
assert_contains "${SCENARIO}/tmt.log" '--context guest_cpus=2' 'processors are passed as context'
assert_lacks "${SCENARIO}/tmt.log" '--hardware' 'no command-line hardware constraint is used'
if [[ $(grep -c -- '--context guest_memory_mib=2048' "${SCENARIO}/tmt.log") -eq 3 ]]; then
    ok 'every invocation on the run carries the same context'
else not_ok 'context missing from an invocation'; fi
assert_contains "${SCENARIO}/staged.list" 'guildmaster-0.1^1-1.el10.x86_64.rpm' 'the manifest packages are staged'
assert_lacks "${SCENARIO}/staged.list" 'stray-file.rpm' 'files outside the manifest are not staged'
assert_own_cleanup
assert_lacks "${SCENARIO}/virsh.log" 'destroy' 'the fallback is not used when tmt cleans up'
assert_contains "${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt" 'image_unchanged_after_run: yes' 'evidence records image immutability'
assert_contains "${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt" 'kernel: stub' 'evidence includes the guest facts'
if [[ ! -d ${SCENARIO}/work/$(run_id) ]]; then ok 'the run directory is removed on success'; else not_ok 'run directory left'; fi

new_guest_scenario guest_release_evidence
run_guest EVIDENCE_KIND=release
assert_status "${status}" 0
if [[ -f ${SCENARIO}/cache/evidence/cuse-rocky-10-release.txt && ! -e ${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt ]]; then
    ok 'post-publication evidence is kept apart from candidate evidence'
else not_ok 'evidence kinds are mixed'; fi

# source_tree_dirty must be "no" only on proof of a clean tree: a failing
# git status is "unknown", and a long list of changes is "yes" however much
# output git writes.
new_guest_scenario guest_evidence_git_fails
printf '#!/bin/sh\nexit 128\n' >"${SCENARIO}/git"
chmod +x "${SCENARIO}/git"
run_guest GIT="${SCENARIO}/git"
assert_status "${status}" 0
assert_contains "${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt" \
    'source_tree_dirty: unknown' 'a failing git status is recorded as unknown'
assert_contains "${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt" \
    'source_commit: unknown' 'a failing git rev-parse is recorded as unknown'

new_guest_scenario guest_evidence_many_changes
cat >"${SCENARIO}/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
*' status '*) for ((i = 0; i < 20000; i++)); do echo " M file-${i}"; done ;;
*) echo 0123456789abcdef0123456789abcdef01234567 ;;
esac
STUB
chmod +x "${SCENARIO}/git"
run_guest GIT="${SCENARIO}/git"
assert_status "${status}" 0
assert_contains "${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt" \
    'source_tree_dirty: yes' 'a tree with many changes is recorded as dirty'

new_guest_scenario guest_evidence_clean_tree
cat >"${SCENARIO}/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
*' status '*) ;;
*) echo 0123456789abcdef0123456789abcdef01234567 ;;
esac
STUB
chmod +x "${SCENARIO}/git"
run_guest GIT="${SCENARIO}/git"
assert_status "${status}" 0
assert_contains "${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt" \
    'source_tree_dirty: no' 'a clean tree is recorded as clean'

new_guest_scenario guest_wrong_image
chmod u+w "${SCENARIO}/image.qcow2"
echo tampered >>"${SCENARIO}/image.qcow2"
run_guest
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'does not match the SHA-256 pinned' 'an image with the wrong bytes is refused'
assert_lacks "${SCENARIO}/tmt.log" 'provision' 'and no guest is provisioned'

new_guest_scenario guest_relative_image_override
run_guest GUEST_IMAGE=relative/image.qcow2
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'GUEST_IMAGE must be an absolute path' 'a relative image path is refused'

new_guest_scenario guest_changed_package
echo tampered >>"${SCENARIO}/rpms/guildmaster-0.1^1-1.el10.x86_64.rpm"
run_guest
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'does not match the checksum in manifest.tsv' 'a package that differs from the manifest is refused'
assert_lacks "${SCENARIO}/tmt.log" ' execute ' 'no test is run'
assert_own_cleanup

new_guest_scenario guest_not_an_overlay
echo '/somewhere/else.qcow2' >"${SCENARIO}/backing"
run_guest
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'which is not the verified image' 'a guest disk backed by another image is refused'
assert_own_cleanup

new_guest_scenario guest_provision_fails
touch "${SCENARIO}/provision_fails"
run_guest
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'provisioning the rocky-10 guest failed' 'a provisioning failure is reported as such'
assert_own_cleanup

new_guest_scenario guest_plan_fails
touch "${SCENARIO}/plan_fails"
run_guest
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'event=workdir_retained' 'logs are kept when the plan fails'
assert_own_cleanup
if [[ ! -e ${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt ]]; then ok 'no evidence for a failed run'; else not_ok 'evidence written for a failed run'; fi

new_guest_scenario guest_image_mutated
touch "${SCENARIO}/image_changes"
run_guest
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'changed during the run' 'a base image that changed during the run fails the run'

new_guest_scenario guest_no_facts
touch "${SCENARIO}/no_facts"
run_guest
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'recorded no facts' 'a run without the environment preflight is not accepted'

new_guest_scenario guest_backing_is_verified_copy
cp "${SCENARIO}/image.qcow2" "${SCENARIO}/copy-in-testcloud-store.qcow2"
echo "${SCENARIO}/copy-in-testcloud-store.qcow2" >"${SCENARIO}/backing"
run_guest
assert_status "${status}" 0
assert_contains "${SCENARIO}/out" 'event=overlay_verified' 'a byte-identical copy of the image is accepted as backing'

new_guest_scenario guest_upgrade_recorded
mkdir -p "${SCENARIO}/upgrade"
echo 'upgrade payload' >"${SCENARIO}/upgrade/guildmaster-0.1^1-1.el10.upgradetest.x86_64.rpm"
run_guest UPGRADE_RPM_DIR="${SCENARIO}/upgrade"
assert_status "${status}" 0
assert_contains "${SCENARIO}/out" 'event=upgrade_rpm_selected' 'upgrade packages are logged with checksums'
assert_contains "${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt" 'upgrade_rpms:' \
    'upgrade package checksums are recorded as evidence'
assert_contains "${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt" \
    "$(sha256sum <"${SCENARIO}/upgrade/guildmaster-0.1^1-1.el10.upgradetest.x86_64.rpm" | cut -d' ' -f1)" \
    'with the checksum of the staged bytes'

new_guest_scenario guest_upgrade_empty
mkdir -p "${SCENARIO}/upgrade"
run_guest UPGRADE_RPM_DIR="${SCENARIO}/upgrade"
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'holds no RPMs' 'an empty upgrade directory is refused'
assert_lacks "${SCENARIO}/tmt.log" ' execute ' 'and no test is run'
assert_lacks "${SCENARIO}/tmt.log" 'provision' 'and no guest is provisioned'

new_guest_scenario guest_preflight_runs_once
cat >"${SCENARIO}/preflight" <<'STUB'
#!/usr/bin/env bash
# Passes the first time; a second run fails, as a disk-space check would once
# the guest's overlay has grown.
if [[ -e ${SCENARIO}/preflight.ran ]]; then
    echo 'preflight_event check=disk_space status=fail' && exit 1
fi
touch "${SCENARIO}/preflight.ran"
echo 'preflight_event check=virtual_provisioner status=ok testcloud=0.0-stub'
echo 'preflight_event check=libvirt_session status=ok libvirt=0.0 qemu=0.0'
STUB
chmod +x "${SCENARIO}/preflight"
run_guest PREFLIGHT="${SCENARIO}/preflight"
assert_status "${status}" 0
assert_contains "${SCENARIO}/cache/evidence/cuse-rocky-10-candidate.txt" \
    'host_virtual_provisioner: testcloud=0.0-stub' \
    'host facts in the evidence come from the initial preflight'

# A failing preflight names the failed check only in its report, which must
# therefore reach the output before the run stops.
new_guest_scenario guest_preflight_failure_is_shown
cat >"${SCENARIO}/preflight" <<'STUB'
#!/usr/bin/env bash
echo 'preflight_event check=virtual_provisioner status=fail detail="stub"'
echo 'preflight_event check=summary status=fail failures=1'
exit 1
STUB
chmod +x "${SCENARIO}/preflight"
run_guest PREFLIGHT="${SCENARIO}/preflight"
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'check=virtual_provisioner status=fail' \
    'the failed check is shown when the preflight fails'
assert_contains "${SCENARIO}/out" 'the environment preflight failed' \
    'the run reports that the preflight failed'
assert_lacks "${SCENARIO}/tmt.log" 'provision' 'no guest is provisioned after a failed preflight'

new_guest_scenario guest_upgrade_dir_unset
run_guest UPGRADE_RPM_DIR=
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'UPGRADE_RPM_DIR is not set' 'a missing upgrade fixture is refused'
assert_lacks "${SCENARIO}/tmt.log" 'provision' 'before any guest is provisioned'

new_guest_scenario guest_cleanup_fallback
touch "${SCENARIO}/cleanup_fails"
run_guest
assert_status "${status}" 0
assert_contains "${SCENARIO}/virsh.log" 'destroy tmt-001-stub' 'the fallback destroys the domain recorded for this run'
if [[ $(grep -c 'destroy' "${SCENARIO}/virsh.log") -eq 1 ]]; then ok 'and no other domain'; else not_ok 'more than one domain destroyed'; fi
if [[ ! -e ${SCENARIO}/work/testcloud/instances/tmt-001-stub ]]; then ok 'and removes its instance directory'; else not_ok 'instance directory left'; fi
assert_contains "${SCENARIO}/out" 'event=guest_destroyed target=rocky-10' 'the fallback is logged'

new_guest_scenario guest_cleanup_fallback_session_unreachable
touch "${SCENARIO}/cleanup_fails" "${SCENARIO}/virsh_list_fails"
run_guest
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'event=guest_cleanup_failed' \
    'an unreachable session is not taken as proof that the guest is gone'
assert_lacks "${SCENARIO}/out" 'method=fallback' 'and the fallback does not claim success'

new_guest_scenario guest_cleanup_fallback_domain_remains
touch "${SCENARIO}/cleanup_fails" "${SCENARIO}/virsh_still_listed"
run_guest
assert_status "${status}" 1
assert_contains "${SCENARIO}/out" 'event=guest_cleanup_failed' \
    'a domain still listed after removal is reported'

echo
echo "CUSE script tests: ${passed} passed, ${failed} failed"
[[ ${failed} -eq 0 ]]
