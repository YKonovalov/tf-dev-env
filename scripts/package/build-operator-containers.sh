#!/bin/bash -e

set -o pipefail

scriptdir=$(realpath $(dirname "$0"))
source "$scriptdir/../../common/common.sh"
source_env

REPODIR=${REPODIR:-"."}

if [[ -z "${CONTRAIL_REGISTRY}" ]]; then
  echo "CONTRAIL_REGISTRY is not set"
  exit 1
fi

export CONTRAIL_REGISTRY

if [[ -z "${CONTRAIL_REPOSITORY}" ]]; then
  echo "CONTRAIL_REPOSITORY is not set"
  exit 1
fi

export CONTRAIL_CONTAINER_TAG=${CONTRAIL_CONTAINER_TAG:-"dev"}
CONTRAIL_KEEP_LOG_FILES=${CONTRAIL_KEEP_LOG_FILES:-'false'}

function append_log() {
  local logfile=$1
  while read line ; do
    if [[ "${CONTRAIL_KEEP_LOG_FILES,,}" == 'true' ]] ; then
      echo "$line" >> $logfile
    else
      echo "$line" | tee -a $logfile
    fi
  done
}

function run_cmd(){
  local me=$(whoami)
  if [[ "root" == "$me" ]] || ! grep -q "^docker:" /etc/group || groups | grep -q 'docker' ; then
    $@
    return
  fi
  if ! grep -q "^docker:.*:$me" /etc/group ; then
    /usr/bin/sudo usermod -aG docker $me
  fi
  echo $@ | sg docker -c bash
}

function build_operator() {
  cd ${REPODIR}/tf-operator

  type go >/dev/null 2>&1 || {
    export PATH=$PATH:/usr/local/go/bin
  }
  export CGO_ENABLED=1

  echo "INFO: build tf-operator"
  local target=${CONTAINER_REGISTRY}/tf-operator:${CONTRAIL_CONTAINER_TAG}
  local build_opts=""
  if [[ "$DISTRO_VER_MAJOR" == '8' ]] ; then
    build_opts+=' --image-builder podman --image-build-args "--format=docker"'
  fi
  run_cmd operator-sdk build $target $build_opts
  run_cmd docker push $target

  # olm bundle
  echo "INFO: build tf-operator bundle for olm"
  local build_tag=${CONTAINER_REGISTRY}/tf-operator-bundle:${CONTRAIL_CONTAINER_TAG}
  build_opts=" --no-cache --tag $build_tag -f deploy/bundle/bundle.Dockerfile deploy/bundle"
  if [[ "$DISTRO_VER_MAJOR" == '8' ]] ; then
    build_opts+=' --format docker'
  fi
  run_cmd docker build $build_opts
  run_cmd docker push $build_tag
}

res=0

operator_logfile="${WORKSPACE}/tf_operator_build_containers.log"
if [ ! -d ${REPODIR}/tf-operator ] ; then
  echo "WARNING: tf-operator is absent. Won't be built"
  exit 0
fi

build_operator 2>&1 | append_log $operator_logfile || res=1

mkdir -p /output/logs/tf-operator
# do not fail script if logs file is absent
mv $operator_logfile /output/logs/tf-operator || /bin/true

exit $res
