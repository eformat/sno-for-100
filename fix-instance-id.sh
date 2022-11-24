#!/bin/bash
# -*- coding: UTF-8 -*-

# aws cli v2 - https://github.com/aws/aws-cli/issues/4992
export AWS_PAGER=""

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[38;5;214m'
NC='\033[0m' # No Color
# env vars
DRYRUN=
KUBEADMIN_PASSWORD=${KUBEADMIN_PASSWORD:-}
BASE_DOMAIN=${BASE_DOMAIN:-}
CLUSTER_NAME=${CLUSTER_NAME:-}
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

restart_instance() {
    set -o pipefail
    aws ec2 stop-instances \
    ${DRYRUN:---dry-run} \
    --region=${region} \
    --instance-ids=$instance_id 2>&1 | tee /tmp/aws-error-file
    if [ "$?" != 0 ]; then
        if egrep -q "DryRunOperation" /tmp/aws-error-file; then
            echo -e "${GREEN}Ignoring - restart_instance stop instance - dry run set${NC}"
        else
            echo -e "🕱${RED}Failed - could not stop $instance_id ?${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN} -> restart_instance stopping [ $instance_id ] OK${NC}"
    fi

    echo -e "${GREEN} -> wait instance-stopped ... [ $instance_id ]${NC}"
    aws ec2 wait instance-stopped \
    ${DRYRUN:---dry-run} \
    --region=${region} \
    --instance-ids $instance_id

    if [ ! -z "$DRYRUN" ]; then
        sleep 120 # fix me spot restart is not elegant
        echo -e "${GREEN} -> instance stopped [ $instance_id ] OK${NC}"
    fi

    aws ec2 start-instances \
    ${DRYRUN:---dry-run} \
    --region=${region} \
    --instance-ids=$instance_id 2>&1 | tee /tmp/aws-error-file
    if [ "$?" != 0 ]; then
        if egrep -q "DryRunOperation" /tmp/aws-error-file; then
            echo -e "${GREEN}Ignoring - restart_instance start instance - dry run set${NC}"
        else
            echo -e "🕱${RED}Failed - could not start $instance_id ?${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN} -> restart_instance starting [ $instance_id ] OK${NC}"
    fi
    set +o pipefail
}

find_vpc_id() {
    local tag_value="$1"
    vpc_id=$(aws ec2 describe-vpcs --region=${region} \
    --query "Vpcs[].VpcId" \
    --filters "Name=tag-value,Values=$tag_value" \
    --output text)
    if [ -z "$vpc_id" ]; then
        echo -e "🕱${RED}Failed - could not find vpc id associated with tag: $tag_value ?${NC}"
        exit 1
    else
        echo "🌴 VpcId set to $vpc_id"
    fi
}

find_router_lb() {
    query='LoadBalancerDescriptions[?VPCId==`'${vpc_id}'`]|[].LoadBalancerName'
    router_load_balancer=$(aws elb describe-load-balancers \
    --region=${region} \
    --query $query \
    --output text)
    if [ -z "$router_load_balancer" ]; then
        echo -e "🕱${RED}Warning - could not find router load balancer ?${NC}"
        exit 1
    else
        echo "🌴 RouterLoadBalancer set to $router_load_balancer"
    fi
}

associate_router_instance() {
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - associate_router_eip - dry run set${NC}"
        return
    fi
    if [ ! -z "$router_load_balancer" ]; then
        aws elb register-instances-with-load-balancer \
        --load-balancer-name $router_load_balancer \
        --instances $instance_id \
        --region=${region}
        if [ "$?" != 0 ]; then
            echo -e "🕱${RED}Failed - could not associate router lb  $router_load_balancer with instance $instance_id ?${NC}"
            exit 1
        else
            # FIXME: Would be better to check the instance is registered and then poll for an InService instance here with a timeout.
            sleep 45
            echo -e "${GREEN} -> associate_router_eip [ $router_load_balancer, $instance_id ] OK${NC}"
        fi
    fi
}

login_openshift() {
    oc login -u kubeadmin -p ${KUBEADMIN_PASSWORD} --server=https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443 --insecure-skip-tls-verify
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed to login to OpenShift https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443 ?${NC}"
        exit 1
    fi
}

find_node_providerid() {
    node_provider_id=$(oc get nodes -o jsonpath='{.items[0].spec.providerID}')
    if [ -z "$node_provider_id" ]; then
        echo -e "🕱${RED}Failed - could not find openshift node providerid ?${NC}"
        exit 1
    else
        echo "🌴 NodeProviderId set to $node_provider_id"
    fi
}

update_providerid_on_node() {
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - update_providerid_on_node - dry run set${NC}"
        return
    fi
    oc debug -T $(oc get node -o name) -- chroot /host bash -c "sed -i \"s|aws:///.*|aws:///$region/$instance_id\\\"|\" /etc/systemd/system/kubelet.service.d/20-aws-providerid.conf"
}

delete_node() {
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - delete_node - dry run set${NC}"
        return
    fi
    oc delete $(oc get node -o name)
}

wait_for_openshift_api() {
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - wait_for_openshift_api - dry run set${NC}"
        return
    fi
    local i=0
    HOST=https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443/healthz
    until [ $(curl -k -s -o /dev/null -w %{http_code} ${HOST}) = "200" ]
    do
        echo -e "${GREEN}Waiting for 200 response from openshift api ${HOST}.${NC}"
        sleep 5
        ((i=i+1))
        if [ $i -gt 100 ]; then
            echo -e "${RED}.Failed - OpenShift api ${HOST} never ready?.${NC}"
            exit 1
        fi
    done
}

# do it all
all() {
    echo "🌴 BASE_DOMAIN set to $BASE_DOMAIN"
    echo "🌴 CLUSTER_NAME set to $CLUSTER_NAME"

    find_region
    find_instance_id "$CLUSTER_NAME-*-master-0"
    find_vpc_id "$CLUSTER_NAME-*-vpc"

    find_router_lb
    associate_router_instance

    login_openshift
    find_node_providerid

    update_providerid_on_node
    delete_node

    restart_instance
    wait_for_openshift_api
}

usage() {
  cat <<EOF 2>&1
usage: $0 [ -d ]

Fix SNO Instance Id's
        -d     do it ! no dry run - else we print out whats going to happen and any non desructive lookups

Optional arguments if not set in environment:

        -b     BASE_DOMAIN - openshift base domain (or export BASE_DOMAIN env var)
        -c     CLUSTER_NAME - openshift cluster name (or export CLUSTER_NAME env var)
        -p     KUBEADMIN_PASSWORD - openshift kubeadmin password from install

This script is rerunnable.

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
        KUBEADMIN_PASSWORD

EOF
  exit 1
}

while getopts db:c:p: opts; do
  case $opts in
    b)
      BASE_DOMAIN=$OPTARG
      ;;
    c)
      CLUSTER_NAME=$OPTARG
      ;;
    d)
      DRYRUN="--no-dry-run"
      ;;
    p)
      KUBEADMIN_PASSWORD=$OPTARG
      ;;
    *)
      usage
      ;;
  esac
done

shift `expr $OPTIND - 1`

# Check for EnvVars
[ ! -z "$AWS_PROFILE" ] && echo "Using AWS_PROFILE: $AWS_PROFILE"
[ -z "$BASE_DOMAIN" ] && echo "🕱 Error: must supply BASE_DOMAIN in env or cli" && exit 1
[ -z "$CLUSTER_NAME" ] && echo "🕱 Error: must supply CLUSTER_NAME in env or cli" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_ACCESS_KEY_ID" ] && echo "🕱 Error: AWS_ACCESS_KEY_ID not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_SECRET_ACCESS_KEY" ] && echo "🕱 Error: AWS_SECRET_ACCESS_KEY not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_DEFAULT_REGION" ] && echo "🕱 Error: AWS_DEFAULT_REGION not set in env" && exit 1
[ -z "$KUBEADMIN_PASSWORD" ] && [ -z "$KUBEADMIN_PASSWORD" ] && echo "🕱 Error: KUBEADMIN_PASSWORD not set in env or cli" && exit 1

all

echo -e "\n🌻${GREEN}AWS SNO Reconfigured OK.${NC}🌻\n"
exit 0
