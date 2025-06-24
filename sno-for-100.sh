#!/bin/bash
# -*- coding: UTF-8 -*-

# aws cli v2 - https://github.com/aws/aws-cli/issues/4992
export AWS_PAGER=""
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)
export KUBECONFIG=$RUN_DIR/cluster/auth/kubeconfig

# env vars
DRYRUN=${DRYRUN:-}
BASE_DOMAIN=${BASE_DOMAIN:-}
CLUSTER_NAME=${CLUSTER_NAME:-}
PULL_SECRET=${PULL_SECRET:-}
SSH_KEY=${SSH_KEY:-}
ROOT_VOLUME_SIZE=${ROOT_VOLUME_SIZE:-100}
INSTANCE_TYPE=${INSTANCE_TYPE:-"m5a.2xlarge"}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-"stable"}
SKIP_SPOT=${SKIP_SPOT:-}
# prog vars
region=
instance_id=
architecture=

# sanity environment check section
CYGWIN_ON=no
MACOS_ON=no
LINUX_ON=no
system_os_flavor=linux
system_os_arch=$(uname -m)
min_bash_version=4

# - try to detect CYGWIN
a=$(uname -a) && al=$(echo "$a" | awk '{ print tolower($0); }') && ac=${al%cygwin} && [[ "$al" != "$ac" ]] && CYGWIN_ON=yes
if [[ "$CYGWIN_ON" == "yes" ]]; then
  echo "CYGWIN  ${system_os_arch} DETECTED - WILL TRY TO ADJUST PATHS"
  system_os_flavor=windows
  min_bash_version=4
fi

# - try to detect MacOS
a=$(uname) && al=$(echo "$a" | awk '{ print tolower($0); }') && ac=${al%darwin} && [[ "$al" != "$ac" ]] && MACOS_ON=yes
[[ "$MACOS_ON" == "yes" ]] && system_os_flavor=mac && min_bash_version=5 && echo -e "${ORANGE}\nmacOS ${system_os_arch} DETECTED${NC}\n"

# - try to detect Linux
a=$(uname) && al=$(echo "$a" | awk '{ print tolower($0); }') && ac=${al%linux} && [[ "$al" != "$ac" ]] && LINUX_ON=yes
[[ "$LINUX_ON" == "yes" ]] && min_bash_version=4

bash_version=$(bash -c 'echo ${BASH_VERSINFO[0]}')
bash_ok=no && [ "${bash_version}" -ge $min_bash_version ] && bash_ok=yes
[[ "$bash_ok" != "yes" ]] && echo "ERROR: BASH VERSION NOT SUPPORTED - PLEASE UPGRADE YOUR BASH INSTALLATION - ABORTING" && exit 1 

# sanity check tools
command -v yq &> /dev/null || { echo >&2 'ERROR: yq not installed. Please install yq tool to continue - Aborting'; exit 1; }
command -v tar &> /dev/null || { echo >&2 'ERROR: tar not installed. Please install tar tool to continue - Aborting'; exit 1; }
command -v curl &> /dev/null || { echo >&2 'ERROR: curl not installed. Please install curl tool to continue - Aborting'; exit 1; }

SED='sed'
if [[ "$MACOS_ON" == "no" ]]; then
  SED='sed'
  command -v sed  &> /dev/null      || { echo >&2 'ERROR: sed not installed. Please install sed 4.2 (or later) to continue - Aborting'; exit 1; }
fi

if [[ "$MACOS_ON" == "yes" ]]; then
  macshed=no
  command -v sed  &> /dev/null && SED='sed'  && macshed=yes
  command -v gsed &> /dev/null && SED='gsed' && macshed=yes
  [[ "$macshed" == "no" ]] && echo >&2 'ERROR: gsed not installed. Please install GNU sed.4.8 (or later)  to continue - Aborting' && exit 1

  # - check sed version on Mac
  macstatus=256
  "$SED" --version &> /dev/null; macstatus=$?
  if [[ "$macstatus" -eq 0 ]]; then
    maxv=$("$SED" --version | head -1 | awk '{print $NF}' | cut -d'.' -f 1)
    minv=$("$SED" --version | head -1 | awk '{print $NF}' | cut -d'.' -f 2)
    [[ "$maxv" -ge "4" ]] && [[ "$minv" -ge "8" ]] && macsed=yes
    unset maxv minv
  else
    macshed=no
  fi
  [[ "$macshed" == "yes" ]] || { echo >&2 'ERROR: GNU sed not found. Please install GNU sed.4.8 (or later) to continue - Aborting'; exit 2; }
  unset macshed macstatus
fi

# set architecture for install-config
[[ "$CYGWIN_ON" == "yes" ]] && architecture=amd64
[[ "$system_os_arch" == "x86_64" ]] && architecture=amd64
[[ "$system_os_arch" == "aarch64" ]] && architecture=arm64

# sanity environment section end

find_region() {
    if [ ! -z "$AWS_DEFAULT_REGION" ]; then
        region="$AWS_DEFAULT_REGION"
    else
        region=$(aws configure get region)
    fi
    if [ -z "$region" ]; then
        echo -e "🕱${RED}Failed - could not find aws region ?${NC}"
        exit 1
    else
        echo "🌴 Region set to $region"
    fi
}

find_instance_id() {
    local tag_value="$1"
    instance_id=$(aws ec2 describe-instances \
    --region=${region} \
    --query "Reservations[].Instances[].InstanceId" \
    --filters "Name=tag-value,Values=$tag_value" "Name=instance-state-name,Values=running" \
    --output text)
    if [ -z "$instance_id" ]; then
        echo -e "🕱${RED}Failed - could not find instance id associated with tag: $tag_value ?${NC}"
        exit 1
    else
        echo "🌴 InstanceId set to $instance_id"
    fi
}

generate_dynamodb() {
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - generate_dynamodb - dry run set${NC}"
        return
    fi
    set -o pipefail
    ${RUN_DIR}/ec2-spot-converter --generate-dynamodb-table 2>&1 | tee /tmp/aws-error-file
    if [ "$?" != 0 ]; then
        if grep -E -q "Table already exists" /tmp/aws-error-file; then
            echo -e "${GREEN}Ignoring - dynamodb table already exists${NC}"
        else
            echo -e "🕱${RED}Failed - to run generate_dynamodb ?${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN} -> generate_dynamodb ran OK${NC}"
    fi
    set +o pipefail
}

prepare_install_config() {
    "$SED" -i "s|baseDomain:.*|baseDomain: $BASE_DOMAIN|" ${RUN_DIR}/install-config.yaml
    "$SED" -i "s|  architecture:.*|  architecture: $architecture|" ${RUN_DIR}/install-config.yaml
    "$SED" -i "s|^      type:.*|      type: $INSTANCE_TYPE|" ${RUN_DIR}/install-config.yaml
    "$SED" -i "s|^        size:.*|        size: $ROOT_VOLUME_SIZE|" ${RUN_DIR}/install-config.yaml
    "$SED" -i "s|^  name:.*|  name: $CLUSTER_NAME|" ${RUN_DIR}/install-config.yaml
    "$SED" -i "s|    region:.*|    region: $region|" ${RUN_DIR}/install-config.yaml
    "$SED" -i "s|pullSecret:.*|pullSecret: '$PULL_SECRET'|" ${RUN_DIR}/install-config.yaml
    "$SED" -i "s|sshKey:.*|sshKey: '$SSH_KEY'|" ${RUN_DIR}/install-config.yaml
    if [ ! -z "$AWS_DEFAULT_ZONES" ]; then
        yq e '.controlPlane.platform.aws.zones = env(AWS_DEFAULT_ZONES)' -i ${RUN_DIR}/install-config.yaml
    fi
    cp ${RUN_DIR}/install-config.yaml ${RUN_DIR}/cluster/install-config.yaml
}

check_if_install_complete() {
    if [ ! -r "$RUN_DIR/cluster/auth/kubeconfig" ]; then
        return 1
    fi
    export KUBECONFIG="$RUN_DIR/cluster/auth/kubeconfig"
    $RUN_DIR/openshift-install wait-for bootstrap-complete --dir=$RUN_DIR/cluster
    if [ "$?" != 0 ]; then
        return 1
    fi
    $RUN_DIR/openshift-install wait-for install-complete --dir=$RUN_DIR/cluster
    if [ "$?" != 0 ]; then
        return 1
    fi
    return 0
}

install_openshift() {
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - install_openshift - dry run set${NC}"
        return
    fi

    if [ ! -d "$RUN_DIR/cluster" ]; then
        mkdir -p cluster
        prepare_install_config
    fi

    if [ check_if_install_complete != 0 ]; then
        echo "🌴 Installing OpenShift..."
        ${RUN_DIR}/openshift-install create cluster --dir=$RUN_DIR/cluster
        echo "$?"
    fi

    if [ ! -r "$RUN_DIR/cluster/auth/kubeconfig" ]; then
        echo -e "🕱${RED}Failed - install_openshift expecting a readable kubeconfig ?${NC}"
        exit 1
    fi
    export KUBECONFIG="$RUN_DIR/cluster/auth/kubeconfig"
}

adjust_single_node() {
    echo "🌴 Running adjust-single-node.sh ..."
    ${RUN_DIR}/adjust-single-node.sh
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed - to run adjust-single-node.sh ?${NC}"
        exit 1
    else
        echo "🌴 adjust-single-node.sh ran OK"
    fi
}

adjust_single_node_416() {
    echo "🌴 Running adjust-single-node-4.16.sh ..."
    ${RUN_DIR}/adjust-single-node-4.16.sh
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed - to run adjust-single-node-4.16.sh ?${NC}"
        exit 1
    else
        echo "🌴 adjust-single-node-4.16.sh ran OK"
    fi
}

ec2_spot_converter() {
    echo "🌴 Running ec2-spot-converter ..."
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - ec2_spot_converter - dry run set${NC}"
        return
    fi
    if [ ! -z "$SKIP_SPOT" ]; then
        echo -e "${GREEN}Ignoring - ec2_spot_converter - skip spot set${NC}"
        return
    fi
    set -o pipefail
    ${RUN_DIR}/ec2-spot-converter --stop-instance --instance-id $instance_id 2>&1 | tee /tmp/aws-error-file
    if [ "$?" != 0 ]; then
        if grep -E -q "is already a Spot instance" /tmp/aws-error-file; then
            echo -e "${GREEN}Ignoring - $instance_id is already a spot instance${NC}"
        else
            echo -e "🕱${RED}Failed - to run ec2-spot-converter ?${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN} -> ec2-spot-converter ran OK${NC}"
        echo -e "${GREEN} -> \t run ec2-spot-converter again to clean up the generated ami and its snapshot...${NC}"
        ${RUN_DIR}/ec2-spot-converter --delete-ami --instance-id $instance_id 2>&1 | tee /tmp/aws-error-file
    fi
    set +o pipefail
}

fix_instance_id() {
    echo "🌴 Running fix-instance-id.sh ..."
    ${RUN_DIR}/fix-instance-id.sh
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed - to run fix-instance-id.sh ?${NC}"
        exit 1
    else
        echo "🌴 fix-instance-id.sh ran OK"
    fi
}

download_adjust_single_node() {
    local ret=$(curl --write-out "%{http_code}" https://raw.githubusercontent.com/eformat/sno-for-100/main/adjust-single-node.sh -o ${RUN_DIR}/adjust-single-node.sh)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download adjust-single-node.sh ?.${NC}"
        return $ret
    fi
    chmod u+x ${RUN_DIR}/adjust-single-node.sh
}

download_adjust_single_node_416() {
    local ret=$(curl --write-out "%{http_code}" https://raw.githubusercontent.com/eformat/sno-for-100/main/adjust-single-node-4.16.sh -o ${RUN_DIR}/adjust-single-node-4.16.sh)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download adjust-single-node-4.16.sh ?.${NC}"
        return $ret
    fi
    chmod u+x ${RUN_DIR}/adjust-single-node-4.16.sh
}

download_fix_instance_id() {
    local ret=$(curl --write-out "%{http_code}" https://raw.githubusercontent.com/eformat/sno-for-100/main/fix-instance-id.sh -o ${RUN_DIR}/fix-instance-id.sh)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download fix-instance-id.sh ?.${NC}"
        return $ret
    fi
    chmod u+x ${RUN_DIR}/fix-instance-id.sh
}

download_ec2_converter() {
    local version=`curl https://raw.githubusercontent.com/jcjorel/ec2-spot-converter/master/VERSION.txt`
    local ret=$(curl --write-out "%{http_code}" https://raw.githubusercontent.com/jcjorel/ec2-spot-converter/master/releases/ec2-spot-converter-${version} -o ${RUN_DIR}/ec2-spot-converter)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download ec2-spot-converter ?.${NC}"
        return $ret
    fi
    #patch script header to use /usr/bin/env instead of referring to /usr/bin/python3 directly
    #this avoid issues with multiple python present in the path
    "$SED" -i 's|\#\!/usr/bin/python3|\#\!/usr/bin/env python3|' ${RUN_DIR}/ec2-spot-converter
    chmod u+x ${RUN_DIR}/ec2-spot-converter
    ret=$(curl --write-out "%{http_code}" https://raw.githubusercontent.com/jcjorel/ec2-spot-converter/master/requirements.txt -o ${RUN_DIR}/requirements.txt)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download ec2-spot-converter requirements file ?.${NC}"
        return $ret
    fi
    # newer versions break with 
    #echo "boto3==1.36.15" > ${RUN_DIR}/requirements.txt
    /usr/bin/env python3 -m pip install -r ${RUN_DIR}/requirements.txt
}

download_openshift_installer() {
    local ret=$(curl --write-out "%{http_code}" https://mirror.openshift.com/pub/openshift-v4/${system_os_arch}/clients/ocp/${OPENSHIFT_VERSION}/openshift-install-${system_os_flavor}.tar.gz -o ${RUN_DIR}/openshift-install-${system_os_flavor}.tar.gz)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download openshift-install-${system_os_flavor}.tar.gz ?.${NC}"
        return $ret
    fi
    tar xzvf openshift-install-${system_os_flavor}.tar.gz
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed - to unzip openshift-install-${system_os_flavor}.tar.gz ?${NC}"
        exit 1
    fi
    chmod u+x ${RUN_DIR}/openshift-install
}

download_openshift_cli() {
    local ret=$(curl --write-out "%{http_code}" https://mirror.openshift.com/pub/openshift-v4/${system_os_arch}/clients/ocp/${OPENSHIFT_VERSION}/openshift-client-${system_os_flavor}.tar.gz -o ${RUN_DIR}/openshift-client-${system_os_flavor}.tar.gz)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download openshift-client-${system_os_flavor}.tar.gz ?.${NC}"
        return $ret
    fi
    tar xzvf openshift-client-${system_os_flavor}.tar.gz
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed - to unzip openshift-client-${system_os_flavor}.tar.gz ?${NC}"
    fi
    chmod u+x ${RUN_DIR}/oc
}

download_install_config() {
    local ret=$(curl --write-out "%{http_code}" https://raw.githubusercontent.com/eformat/sno-for-100/main/install-config.yaml -o ${RUN_DIR}/install-config.yaml)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download install-config.yaml ?.${NC}"
        return $ret
    fi
}

version() { 
    echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }';
}

# do it all
all() {
    find_region
    generate_dynamodb

    install_openshift

    if [ "$OPENSHIFT_VERSION" == "stable" ] || [ $(version "$OPENSHIFT_VERSION") > $(version "4.15.99") ]; then
        adjust_single_node_416
    else
        adjust_single_node
    fi

    find_instance_id "$CLUSTER_NAME-*-master-0"
    ec2_spot_converter

    fix_instance_id
}


usage() {
  cat <<EOF 2>&1
usage: $0 [ -d -b <BASE_DOMAIN> -c <CLUSTER_NAME> -p <PULL_SECRET> -s <SSH_KEY> -v <ROOT_VOLUME_SIZE> -t <INSTANCE_TYPE> -o <OPENSHIFT_VERSION> ]

Provision a SNO for 100 spot instace. By default dry-run is ON ! You must set -d to doIt™️
        -d     do it ! no dry run - else we print out whats going to happen and any non desructive lookups

Optional arguments if not set in environment:

        -b     BASE_DOMAIN  - openshift base domain (or export BASE_DOMAIN env var)
        -c     CLUSTER_NAME - openshift cluster name (or export CLUSTER_NAME env var)
        -p     PULL_SECRET  - openshift pull secret (or export PULL_SECRET env var) e.g PULL_SECRET=\$(cat ~/Downloads/pull-secret)
        -s     SSH_KEY      - openshift ssh key (or export SSH_KEY env var) e.g. SSH_KEY=\$(cat ~/.ssh/id_rsa.pub)
        -v     ROOT_VOLUME_SIZE - root vol size in GB (or export ROOT_VOLUME_SIZE env var, default: 100)
        -t     INSTANCE_TYPE - instance type (or export INSTANCE_TYPE, default: m5a.2xlarge)
        -o     OPENSHIFT_VERSION - OpenShift Version (or export OPENSHIFT_VERSION env var default: stable)

This script is rerunnable. It will download the artifacts it needs to run into the current working directory.

Environment Variables:
    Export these in your environment.

        AWS_PROFILE     use a pre-configured aws profile (~/.aws/config and ~/.aws/credentials)

    OR export these in your environment:

        AWS_ACCESS_KEY_ID
        AWS_SECRET_ACCESS_KEY
        AWS_DEFAULT_REGION
        AWS_DEFAULT_ZONES (Optional array list - e.g ["us-east-2b","us-east-2c"])

    Optionally if not set on command line:

        BASE_DOMAIN
        CLUSTER_NAME
        PULL_SECRET
        SSH_KEY
        ROOT_VOLUME_SIZE
        INSTANCE_TYPE
        OPENSHIFT_VERSION

Example:

    export AWS_PROFILE=rhpds
    export AWS_DEFAULT_REGION=us-east-2
    export AWS_DEFAULT_ZONES=["us-east-2a"]
    export CLUSTER_NAME=foo-sno
    export BASE_DOMAIN=demo.redhatlabs.dev
    export PULL_SECRET=\$(cat ~/tmp/pull-secret)
    export SSH_KEY=\$(cat ~/.ssh/id_rsa.pub)

    mkdir my-run && cd my-run
    $0 -d

EOF
  exit 1
}

while getopts b:c:p:s:v:t:o:d opt; do
  case $opt in
    b)
      export BASE_DOMAIN=$OPTARG
      ;;
    c)
      export CLUSTER_NAME=$OPTARG
      ;;
    d)
      export DRYRUN="--no-dry-run"
      ;;
    p)
      export PULL_SECRET=$OPTARG
      ;;
    s)
      export SSH_KEY=$OPTARG
      ;;
    v)
      export ROOT_VOLUME_SIZE=$OPTARG
      ;;
    t)
      export INSTANCE_TYPE=$OPTARG
      ;;
    o)
      export OPENSHIFT_VERSION=$OPTARG
      ;;
    *)
      usage
      ;;
  esac
done

shift `expr $OPTIND - 1`

# Check for EnvVars
[ ! -z "$AWS_PROFILE" ] && echo "🌴 Using AWS_PROFILE: $AWS_PROFILE"
[ -z "$BASE_DOMAIN" ] && echo "🕱 Error: must supply BASE_DOMAIN in env or cli" && exit 1
[ -z "$CLUSTER_NAME" ] && echo "🕱 Error: must supply CLUSTER_NAME in env or cli" && exit 1
[ -z "$PULL_SECRET" ] && echo "🕱 Error: must supply PULL_SECRET in env or cli" && exit 1
[ -z "$SSH_KEY" ] && echo "🕱 Error: must supply SSH_KEY in env or cli" && exit 1
[ -z "$INSTANCE_TYPE" ] && echo "🕱 Error: must supply INSTANCE_TYPE in env or cli" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_ACCESS_KEY_ID" ] && echo "🕱 Error: AWS_ACCESS_KEY_ID not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_SECRET_ACCESS_KEY" ] && echo "🕱 Error: AWS_SECRET_ACCESS_KEY not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_DEFAULT_REGION" ] && echo "🕱 Error: AWS_DEFAULT_REGION not set in env" && exit 1

# Download tools if the do not exist
[ ! -r "$RUN_DIR/install-config.yaml" ] && echo -e "💀${ORANGE}: install-config.yaml not found downloading${NC}" && download_install_config
[ ! -r "$RUN_DIR/adjust-single-node.sh" ] && echo -e "💀${ORANGE}: adjust-single-node.sh not found downloading${NC}" && download_adjust_single_node
[ ! -r "$RUN_DIR/adjust-single-node-4.16.sh" ] && echo -e "💀${ORANGE}: adjust-single-node-4.16.sh not found downloading${NC}" && download_adjust_single_node_416
[ ! -r "$RUN_DIR/fix-instance-id.sh" ] && echo -e "💀${ORANGE}: fix-instance-id.sh not found downloading${NC}" && download_fix_instance_id
[ ! -r "$RUN_DIR/ec2-spot-converter" ] && echo -e "💀${ORANGE}: ec2-spot-converter not found downloading${NC}" && download_ec2_converter
[ ! -r "$RUN_DIR/openshift-install-${system_os_flavor}.tar.gz" ] && echo -e "💀${ORANGE}: openshift-install-${system_os_flavor}.tar.gz not found downloading${NC}" && download_openshift_installer
[ ! -r "$RUN_DIR/openshift-client-${system_os_flavor}.tar.gz" ] && echo -e "💀${ORANGE}: openshift-client-${system_os_flavor}.tar.gz not found downloading${NC}" && download_openshift_cli

all

echo -e "\n🌻${GREEN}AWS SNO Reconfigured OK.${NC}🌻\n"
exit 0
