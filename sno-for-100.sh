#!/bin/bash
# -*- coding: UTF-8 -*-

# aws cli v2 - https://github.com/aws/aws-cli/issues/4992
export AWS_PAGER=""
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)
# env vars
DRYRUN=${DRYRUN:-}
BASE_DOMAIN=${BASE_DOMAIN:-}
CLUSTER_NAME=${CLUSTER_NAME:-}
PULL_SECRET=${PULL_SECRET:-}
SSH_KEY=${SSH_KEY:-}
ROOT_VOLUME_SIZE=${ROOT_VOLUME_SIZE:-100}
INSTANCE_TYPE=${INSTANCE_TYPE:-"m5a.2xlarge"}
# prog vars
region=
instance_id=

find_region() {
    if [ ! -z "$AWS_REGION" ]; then
        region="$AWS_REGION"
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
        if egrep -q "Table already exists" /tmp/aws-error-file; then
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
    sed -i "s|baseDomain:.*|baseDomain: $BASE_DOMAIN|" ${RUN_DIR}/install-config.yaml
    sed -i "s|^      type:.*|      type: $INSTANCE_TYPE|" ${RUN_DIR}/install-config.yaml
    sed -i "s|^        size:.*|        size: $ROOT_VOLUME_SIZE|" ${RUN_DIR}/install-config.yaml
    sed -i "s|^  name:.*|  name: $CLUSTER_NAME|" ${RUN_DIR}/install-config.yaml
    sed -i "s|    region:.*|    region: $region|" ${RUN_DIR}/install-config.yaml
    sed -i "s|pullSecret:.*|pullSecret: '$PULL_SECRET'|" ${RUN_DIR}/install-config.yaml
    sed -i "s|sshKey:.*|sshKey: '$SSH_KEY'|" ${RUN_DIR}/install-config.yaml
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

ec2_spot_converter() {
    echo "🌴 Running ec2-spot-converter ..."
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - ec2_spot_converter - dry run set${NC}"
        return
    fi
    set -o pipefail
    ${RUN_DIR}/ec2-spot-converter --stop-instance --instance-id $instance_id 2>&1 | tee /tmp/aws-error-file
    if [ "$?" != 0 ]; then
        if egrep -q "is already a Spot instance" /tmp/aws-error-file; then
            echo -e "${GREEN}Ignoring - $instance_id is already a spot instance${NC}"
        else
            echo -e "🕱${RED}Failed - to run ec2-spot-converter ?${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN} -> ec2-spot-converter ran OK${NC}"
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
    chmod u+x ${RUN_DIR}/ec2-spot-converter
}

download_openshift_installer() {
    local ret=$(curl --write-out "%{http_code}" https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-install-linux.tar.gz -o ${RUN_DIR}/openshift-install-linux.tar.gz)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download openshift-install-linux.tar.gz ?.${NC}"
        return $ret
    fi
    tar xzvf openshift-install-linux.tar.gz
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed - to unzip openshift-install-linux.tar.gz ?${NC}"
        exit 1
    fi
    chmod u+x ${RUN_DIR}/openshift-install
}

download_openshift_cli() {
    local ret=$(curl --write-out "%{http_code}" https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz -o ${RUN_DIR}/openshift-client-linux.tar.gz)
    if [ "$ret" != "200" ]; then
        echo -e "🕱${RED}Failed - to download openshift-client-linux.tar.gz ?.${NC}"
        return $ret
    fi
    tar xzvf openshift-client-linux.tar.gz
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed - to unzip openshift-client-linux.tar.gz ?${NC}"
        #exit 1
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

# do it all
all() {
    find_region
    generate_dynamodb

    install_openshift
    adjust_single_node

    find_instance_id "$CLUSTER_NAME-*-master-0"
    ec2_spot_converter

    fix_instance_id
}


usage() {
  cat <<EOF 2>&1
usage: $0 [ -d -b <BASE_DOMAIN> -c <CLUSTER_NAME> -p <PULL_SECRET> -s <SSH_KEY> -v <ROOT_VOLUME_SIZE> -t <INSTANCE_TYPE> ]

Provision a SNO for 100 spot instace. By default dry-run is ON ! You must set -d to doIt™️
        -d     do it ! no dry run - else we print out whats going to happen and any non desructive lookups

Optional arguments if not set in environment:

        -b     BASE_DOMAIN  - openshift base domain (or export BASE_DOMAIN env var)
        -c     CLUSTER_NAME - openshift cluster name (or export CLUSTER_NAME env var)
        -p     PULL_SECRET  - openshift pull secret (or export PULL_SECRET env var) e.g PULL_SECRET=\$(cat ~/Downloads/pull-secret)
        -s     SSH_KEY      - openshift ssh key (or export SSH_KEY env var) e.g. SSH_KEY=\$(cat ~/.ssh/id_rsa.pub)
        -v     ROOT_VOLUME_SIZE - root vol size in GB (or export ROOT_VOLUME_SIZE env var, default: 100)
        -t     INSTANCE_TYPE - instance type (or export INSTANCE_TYPE, default: m5a.2xlarge)

This script is rerunnable. It will download the artifacts it needs to run into the current working directory.

Environment Variables:
    Export these in your environment.

        AWS_PROFILE     use a pre-configured aws profile (~/.aws/config and ~/.aws/credentials)

    OR export these in your environment:

        AWS_ACCESS_KEY_ID
        AWS_SECRET_ACCESS_KEY
        AWS_DEFAULT_REGION

    Optionally if not set on command line:

        BASE_DOMAIN
        CLUSTER_NAME
        PULL_SECRET
        SSH_KEY
        ROOT_VOLUME_SIZE
        INSTANCE_TYPE

Example:

    export AWS_PROFILE=rhpds
    export AWS_REGION=ap-southeast-2
    export CLUSTER_NAME=foo-sno
    export BASE_DOMAIN=demo.redhatlabs.dev
    export PULL_SECRET=\$(cat ~/tmp/pull-secret)
    export SSH_KEY=\$(cat ~/.ssh/id_rsa.pub)

    mkdir my-run && cd my-run
    $0 -d

EOF
  exit 1
}

while getopts b:c:p:s:v:t:d opt; do
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
[ ! -r "$RUN_DIR/fix-instance-id.sh" ] && echo -e "💀${ORANGE}: fix-instance-id.sh not found downloading${NC}" && download_fix_instance_id
[ ! -r "$RUN_DIR/ec2-spot-converter" ] && echo -e "💀${ORANGE}: ec2-spot-converter not found downloading${NC}" && download_ec2_converter
[ ! -r "$RUN_DIR/openshift-install-linux.tar.gz" ] && echo -e "💀${ORANGE}: openshift-install-linux.tar.gz not found downloading${NC}" && download_openshift_installer
[ ! -r "$RUN_DIR/openshift-client-linux.tar.gz" ] && echo -e "💀${ORANGE}: openshift-client-linux.tar.gz not found downloading${NC}" && download_openshift_cli

all

echo -e "\n🌻${GREEN}AWS SNO Reconfigured OK.${NC}🌻\n"
exit 0
