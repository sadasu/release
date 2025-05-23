#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function set_proxy_env(){
    # Setup proxy if it's present in the shared dir
    if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
        # shellcheck disable=SC1091
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
}

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response try max_retries payload="${1}"
    if [[ "${payload}" =~ "@sha256:" ]]; then
        digest="$(echo "${payload}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${payload}" -o json | jq -r ".digest")"
        echo "The target image is using tagname pullspec, its digest is ${digest}"
    fi
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    try=0
    max_retries=3
    response=0
    while (( try < max_retries && response != 200 )); do
        echo "Trying #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl -L --silent --output /dev/null --write-out %"{http_code}" "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
        (( try += 1 ))
        sleep 60
    done
    if (( response == 200 )); then
        echo "${payload} is signed" && return 0
    else
        echo "Seem like ${payload} is not signed" && return 1
    fi
}

function mirror_image(){
    local target_version cmd mirror_options
    local apply_sig_together="$1"
    local mirror_crd_type="${2:-icsp}"

    target_version=$(oc adm release info "${TARGET}" --output=json | jq .metadata.version)
   
    echo "Mirroring ${target_version} (${TARGET}) to ${MIRROR_RELEASE_IMAGE_REPO}"

    mirror_options="--insecure=true"
    # check whether the oc command supports the extra options and add them to the args array.
    if oc adm release mirror -h | grep -q -- --keep-manifest-list; then
        echo "Adding --keep-manifest-list to the mirror command."
        mirror_options="${mirror_options} --keep-manifest-list=true"
    else
        echo "This verison of oc does not support --keep-manifest-list, skip it."
    fi

    if oc adm release mirror -h | grep -q -- --print-mirror-instructions; then
        echo "Adding --print-mirror-instructions to the mirror command."
        mirror_options="${mirror_options} --print-mirror-instructions=${mirror_crd_type}"
    else
        echo "This version of oc does not support --print-mirror-instructions, skip it."
    fi

    cmd="oc adm release mirror -a ${PULL_SECRET} ${mirror_options} --from=${TARGET} --to=${MIRROR_RELEASE_IMAGE_REPO}"
    if [[ "${APPLY_SIG}" == "true" ]]; then
        cmd="${cmd} --release-image-signature-to-dir=${SAVE_SIG_TO_DIR}"
        if [[ "${apply_sig_together}" == "true" ]]; then
            set_proxy_env
            cmd="${cmd} --apply-release-image-signature --overwrite"
        fi
    fi
    run_command "${cmd} | tee ${MIRROR_OUT_FILE}"
}

function apply_signature(){
    if [[ "${APPLY_SIG}" == "true" ]]; then
        echo "Apply signature against cluster..."
        #when mirroring images using oc 4.11+, a signature file with 'json' suffix would be created,
        #but the older verison of oc would create a signature file with 'yaml' suffix.
        run_command "oc apply -f ${SAVE_SIG_TO_DIR}/signature-*.* --overwrite=true"
    fi
}

function update_icsp(){
    local source_release_image_repo mirror_crd_resource="${1:-ImageContentSourcePolicy}"

    source_release_image_repo="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE%:*}"
    source_release_image_repo="${source_release_image_repo%@sha256*}"
    if [[ "${source_release_image_repo}" != "${MIRROR_RELEASE_IMAGE_REPO}" ]] && ! oc get ${mirror_crd_resource} example -oyaml; then
        echo "Target image has different repo with source image and icsp example is not present, creating icsp"
        if [[ ! -f "${MIRROR_OUT_FILE}" ]]; then
            echo >&2 "${MIRROR_OUT_FILE} not found" && return 1
        fi
        sed -n '/To use the new mirrored repository for upgrades, use the following to create an '${mirror_crd_resource}':/,/configmap.*/{//!p;}' "${MIRROR_OUT_FILE}"  | grep -v '^$' > "${CLUSTER_MIRROR_CONF_FILE}"
        run_command "cat ${CLUSTER_MIRROR_CONF_FILE}"
        run_command "oc create -f ${CLUSTER_MIRROR_CONF_FILE}"
    fi
}

# Extract oc binary which is supposed to be identical with target release
# Default oc on OCP 4.16 not support OpenSSL 1.x
function extract_oc(){
    echo -e "Extracting oc\n"
    local target_version minor_version retry=5 tmp_oc="/tmp/client-2" binary='oc'
    mkdir -p ${tmp_oc}
    target_version="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
    minor_version="$(echo "${target_version}" | cut -f2 -d.)"
    if (( minor_version > 15 )) && (openssl version | grep -q "OpenSSL 1") ; then
        binary='oc.rhel8'
    fi
    while ! (env "NO_PROXY=*" "no_proxy=*" oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --command=${binary} --to=${tmp_oc} ${TARGET});
    do
        echo >&2 "Failed to extract oc binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_oc}/oc ${OC_DIR} -f
    export PATH="$PATH"
    which oc
    oc version --client
    return 0
}

# check if any of cases is enabled via ENABLE_OTA_TEST
function check_ota_case_enabled() {
    local case_id
    local cases_array=("$@")
    for case_id in "${cases_array[@]}"; do
        # shellcheck disable=SC2076
        if [[ " ${ENABLE_OTA_TEST} " =~ " ${case_id} " ]]; then
            echo "${case_id} is enabled via ENABLE_OTA_TEST on this job."
            return 0
        fi
    done
    return 1
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Get the target upgrades release, by default, OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is the target release
# If it's serial upgrades then override-upgrade file will store the release and overrides OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE
# upgrade-edge file expects a comma separated releases list like target_release1,target_release2,...
export TARGET_RELEASES=("${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}")
if [[ -f "${SHARED_DIR}/upgrade-edge" ]]; then
    release_string="$(< "${SHARED_DIR}/upgrade-edge")"
    # shellcheck disable=SC2207
    TARGET_RELEASES=($(echo "$release_string" | tr ',' ' ')) 
fi
echo "Upgrade targets are ${TARGET_RELEASES[*]}"

# private mirror registry host
# <public_dns>:<port>
if [[ ! -f "${SHARED_DIR}/mirror_registry_url" ]]; then
    echo >&2 "File ${SHARED_DIR}/mirror_registry_url does not exist." && exit 1
fi

MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"
export MIRROR_REGISTRY_HOST

# combine custom registry credential and default pull secret
if [[ ! -f "/var/run/vault/mirror-registry/registry_creds" ]]; then
    echo >&2 "/var/run/vault/mirror-registry/registry_creds does not exist." && exit 1
fi
export PULL_SECRET="${SHARED_DIR}/new_pull_secret"
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${PULL_SECRET}"

trap 'rm -f "${PULL_SECRET}"' ERR EXIT TERM

mirror_crd_type='icsp'
mirror_crd_resource='ImageContentSourcePolicy'
if [[ "${ENABLE_IDMS}" == "yes" ]]; then
    mirror_crd_type="idms"
    mirror_crd_resource="ImageDigestMirrorSet"
fi

export MIRROR_OUT_FILE="${SHARED_DIR}/mirror"
export CLUSTER_MIRROR_CONF_FILE="${SHARED_DIR}/cluster_mirror_conf.yaml"

# Target version oc will be extract in the /tmp/client directory, use it first
mkdir -p /tmp/client
export OC_DIR="/tmp/client"
export PATH=${OC_DIR}:$PATH

for target in "${TARGET_RELEASES[@]}"
do
    export TARGET="${target}"
    if ! check_signed "${TARGET}"; then
        echo "You're mirroring an unsigned images, don't apply signature"
        APPLY_SIG="false"
        SAVE_SIG_TO_DIR=""
        if check_ota_case_enabled "OCP-30832" "OCP-27986"; then
            echo "The case need to run against a signed target image!"
            exit 1
        fi
    else
        echo "You're mirroring a signed images, will apply signature"
        APPLY_SIG="true"
        SAVE_SIG_TO_DIR=$(mktemp -d)
    fi
    export APPLY_SIG
    export SAVE_SIG_TO_DIR

    extract_oc

    if check_ota_case_enabled "OCP-30832"; then
        MIRROR_RELEASE_IMAGE_REPO="${MIRROR_REGISTRY_HOST}/ota_auto/ocp"
        mirror_apply_sig_together="true"
    else
        mirror_release_image="${MIRROR_REGISTRY_HOST}/${TARGET#*/}"
        MIRROR_RELEASE_IMAGE_REPO="${mirror_release_image%:*}"
        MIRROR_RELEASE_IMAGE_REPO="${MIRROR_RELEASE_IMAGE_REPO%@sha256*}"
        mirror_apply_sig_together="false"
    fi
    export MIRROR_RELEASE_IMAGE_REPO
    mirror_image "${mirror_apply_sig_together}" "${mirror_crd_type}"
    set_proxy_env
    # OCP-27986
    if [[ "${mirror_apply_sig_together}" == "false" ]]; then
        apply_signature
    fi
    update_icsp "${mirror_crd_resource}"
    rm -f "${MIRROR_OUT_FILE}" "${CLUSTER_MIRROR_CONF_FILE}"
done
