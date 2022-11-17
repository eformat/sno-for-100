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
BASE_DOMAIN=${BASE_DOMAIN:-}
CLUSTER_NAME=${CLUSTER_NAME:-}
# prog vars
region=
instance_id=
vpc_id=
master_sg=
eip=
eip_alloc=
public_route_table_id=
private_route_table_ids=
public_hosted_zone=
private_hosted_zone=
private_instance_ip=
nat_gateways=
network_load_balancers=
router_load_balancer=

find_region() {
    if [ ! -z "$AWS_REGION" ]; then 
        region="$AWS_REGION"
    fi
    region=$(aws configure get region)
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

find_master_sg() {
    local tag_value="$1"
    master_sg=$(aws ec2 describe-security-groups \
      --region=${region} \
    --query "SecurityGroups[].GroupId" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --filters "Name=tag-value,Values=$tag_value" \
    --output text)
    if [ -z $vpc_id ]; then
        echo -e "🕱${RED}Failed - could not find master security group associated with vpc: $vpc_id and tag: $tag_value ?${NC}"
        exit 1
    else
        echo "🌴 MasterSecurityGroup set to $master_sg"
    fi
}

update_master_sg() {
    set -o pipefail
    # update master security group: allow 6443 (tcp)
    aws ec2 authorize-security-group-ingress \
    --region=${region} \
    ${DRYRUN:---dry-run} \
    --group-id ${master_sg} \
    --ip-permissions '[{"IpProtocol": "tcp", "FromPort": 6443, "ToPort":6443, "IpRanges": [{"CidrIp": "0.0.0.0/0","Description": "sno-100"}]}]' \
    --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=sno-100,Value=sno-100}]" 2>&1 | tee /tmp/aws-error-file
    if [ "$?" != 0 ]; then
        if egrep -q "InvalidPermission.Duplicate|DryRunOperation" /tmp/aws-error-file; then
            echo -e "${GREEN}Ignoring - master security group rule already exists or dry-run set ?${NC}"
        else
            echo -e "🕱${RED}Failed - problem authorizing master securty group setting ?${NC}"
            exit 1
        fi
    fi
    # update master security group: allow 30000 to 32767 (tcp & udp) from 0.0.0.0/0 for nodeport services
    aws ec2 authorize-security-group-ingress \
    --region=${region} \
    ${DRYRUN:---dry-run} \
    --group-id ${master_sg} \
    --ip-permissions '[{"IpProtocol": "tcp", "FromPort": 30000, "ToPort":32767, "IpRanges": [{"CidrIp": "0.0.0.0/0","Description": "sno-100"}]},{"IpProtocol": "udp", "FromPort": 30000, "ToPort":32767, "IpRanges": [{"CidrIp": "0.0.0.0/0","Description": "sno-100"}]}]' \
    --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=sno-100,Value=sno-100}]" 2>&1 | tee /tmp/aws-error-file
    if [ "$?" != 0 ]; then
        if egrep -q "InvalidPermission.Duplicate|DryRunOperation" /tmp/aws-error-file; then
            echo -e "${GREEN}Ignoring - master security group rule already exists or dry-run set ?${NC}"
        else
            echo -e "🕱${RED}Failed - problem authorizing master securty group setting ?${NC}"
            exit 1
        fi
    fi
    # update master security group - add rules that were attached to elb to master from 0.0.0.0/0 to 443, 80, echo
    aws ec2 authorize-security-group-ingress \
    --region=${region} \
    ${DRYRUN:---dry-run} \
    --group-id ${master_sg} \
    --ip-permissions '[{"IpProtocol": "tcp", "FromPort": 443, "ToPort":443, "IpRanges": [{"CidrIp": "0.0.0.0/0","Description": "sno-100"}]},{"IpProtocol": "tcp", "FromPort": 80, "ToPort":80, "IpRanges": [{"CidrIp": "0.0.0.0/0","Description": "sno-100"}]},{"IpProtocol": "icmp", "FromPort": 8, "ToPort": -1,"IpRanges": [{"CidrIp": "0.0.0.0/0","Description": "sno-100"}]}]' \
    --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=sno-100,Value=sno-100}]" 2>&1 | tee /tmp/aws-error-file
    if [ "$?" != 0 ]; then
        if egrep -q "InvalidPermission.Duplicate|DryRunOperation" /tmp/aws-error-file; then
            echo -e "${GREEN}Ignoring - master security group rule already exists or dry-run set ?${NC}"
        else
            echo -e "🕱${RED}Failed - problem authorizing master securty group setting ?${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN} -> update_master_sg OK${NC}"
    set +o pipefail
}

find_or_allocate_eip() {
    set -o pipefail
    # check if we have sno-100 eip already
    read -r eip eip_alloc < <(aws ec2 describe-addresses \
    --region=${region} \
    --query "Addresses[].[PublicIp, AllocationId]" \
    --filters "Name=tag-value,Values=sno-100" \
    --output text)
    if [ -z "$eip" ]; then
        # allocate a new elastic ip address
        aws ec2 allocate-address \
        --domain vpc \
        ${DRYRUN:---dry-run} \
        --region=${region} \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=sno-100,Value=sno-100}]" 2>&1 | tee /tmp/aws-error-file
        if [ "$?" != 0 ]; then
            if egrep -q "DryRunOperation" /tmp/aws-error-file; then
                echo -e "${GREEN}Ignoring - allocate_eip - dry run set ${NC}"
            else
                echo -e "🕱${RED}Failed - problem allocating elastic ip ?${NC}"
                exit 1
            fi
        else
            read -r eip eip_alloc < <(aws ec2 describe-addresses \
            --region=${region} \
            --query "Addresses[].[PublicIp, AllocationId]" \
            --filters "Name=tag-value,Values=sno-100" \
            --output text)
            if [ -z "$eip" ]; then
                echo -e "🕱${RED}Failed - problem finding allocated elastic ip ?${NC}"
                exit 1
            fi
            echo -e "${GREEN} -> allocate_eip [ $eip, $eip_alloc ] OK${NC}"
        fi
    else
        echo -e "${GREEN} -> found existing eip [ $eip, $eip_alloc ] OK${NC}"
    fi
    set +o pipefail
}

associate_eip() {
    set -o pipefail
    aws ec2 associate-address \
    --region=${region} \
    ${DRYRUN:---dry-run} \
    --allocation-id ${eip_alloc:-a1000} \
    --instance-id $instance_id 2>&1 | tee /tmp/aws-error-file
    if [ "$?" != 0 ]; then
        if egrep -q "DryRunOperation" /tmp/aws-error-file; then
            echo -e "${GREEN}Ignoring - associate_eip - dry run set ${NC}"
        else
            echo -e "🕱${RED}Failed - could not associate eip $eip with instance $instance_id ?${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN} -> associate_eip [ $eip, $eip_alloc, $instance_id ] OK${NC}"
    fi
    set +o pipefail
}

find_public_route_table() {
    local tag_value="$1"
    public_route_table_id=$(aws ec2 describe-route-tables --region=${region} \
    --query "RouteTables[].RouteTableId" \
    --filters "Name=tag-value,Values=$tag_value" "Name=vpc-id,Values=${vpc_id}" \
    --output text)
    if [ -z "$public_route_table_id" ]; then
        echo -e "🕱${RED}Failed - could not find public route table id tag: $tag_value ?${NC}"
        exit 1
    else
        echo "🌴 PublicRouteTableId set to $public_route_table_id"
    fi
}

find_private_route_tables() {
    local tag_value="$1"
    private_route_table_ids=$(aws ec2 describe-route-tables --region=${region} \
    --query "RouteTables[].Associations[].RouteTableAssociationId" \
    --filters "Name=tag-value,Values=$tag_value" "Name=vpc-id,Values=${vpc_id}" \
    --output text)
    if [ -z "$private_route_table_ids" ]; then
        echo -e "💀${ORANGE}Warning - could not find private route table assoc ids for tag: $tag_value - continuing, they may have been deleted already ?${NC}"
    else
        echo "🌴 PrivateRouteTableIds set to $private_route_table_ids"
    fi
}

update_private_routes() {
    set -o pipefail
    if [ ! -z "$private_route_table_ids" ]; then
        for x in $private_route_table_ids; do
            aws ec2 replace-route-table-association \
            ${DRYRUN:---dry-run} \
            --association-id $x \
            --route-table-id $public_route_table_id \
            --region=${region} 2>&1 | tee /tmp/aws-error-file
            if [ "$?" != 0 ]; then
                if egrep -q "DryRunOperation" /tmp/aws-error-file; then
                    echo -e "${GREEN}Ignoring - update_private_routes - dry run set${NC}"
                else
                    echo -e "🕱${RED}Failed - could not associate private $x with public route table $public_route_table_id ?${NC}"
                    exit 1
                fi
            else
                echo -e "${GREEN} -> update_private_routes [ $x,  $public_route_table_id ] OK${NC}"
            fi
        done
    fi
    set +o pipefail
}

find_public_route53_hostedzone() {
    local dns_name="$1"
    public_hosted_zone=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$dns_name" \
    --max-items 1 \
    --query "HostedZones[].[Id]" \
    --output text)
    if [ -z "$public_hosted_zone" ]; then
        echo -e "🕱${RED}Failed - could not find public route53 hostedzone for: $dns_name ?${NC}"
        exit 1
    else
        echo "🌴 PublicHostedZone set to $public_hosted_zone"
    fi
}

update_route53_public() {
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - update_route53_public - dry run set${NC}"
        return
    fi
    local dns_name="$1"
    for x in "api"; do
        cat << EOF > /tmp/route53_policy
        {
            "Changes": [
              {
                "Action": "UPSERT",
                "ResourceRecordSet": {
                  "Name": "$x.$dns_name",
                  "Type": "A",
                  "TTL": 300,
                  "ResourceRecords": [
                    {
                      "Value": "$eip"
                    }
                  ]
                }
              }
            ]
          }
EOF

        aws route53 change-resource-record-sets \
        --region=${region} \
        --hosted-zone-id $(echo ${public_hosted_zone} | sed 's/\/hostedzone\///g') \
        --change-batch file:///tmp/route53_policy
        if [ "$?" != 0 ]; then
            echo -e "🕱${RED}Failed - could not update route53 public record for $x.$dns_name, $eip ?${NC}"
            exit 1
        else
            echo -e "${GREEN} -> update_route53_public[ $x.$dns_name, $eip ] OK${NC}"
        fi
    done
}

find_private_route53_hostedzone() {
    local dns_name="$1"
    private_hosted_zone=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$dns_name" \
    --max-items 1 \
    --query "HostedZones[].[Id]" \
    --output text)
    if [ -z "$private_hosted_zone" ]; then
        echo -e "🕱${RED}Failed - could not find private route53 hostedzone for: $dns_name ?${NC}"
        exit 1
    else
        echo "🌴 PrivateHostedZone set to $private_hosted_zone"
    fi
}

find_instance_private_ip_address() {
    private_instance_ip=$(aws ec2 describe-instances \
    --region=${region} \
    --filters "Name=instance-id,Values=$instance_id" \
    --query 'Reservations[*].Instances[*].[PrivateIpAddress]' \
    --output text)
    if [ -z "$private_instance_ip" ]; then
        echo -e "🕱${RED}Failed - could not find private instance ip address for $instance_id ?${NC}"
        exit 1
    else
        echo "🌴 PrivateInstanceIp set to $private_instance_ip"
    fi
}

update_route53_private() {
    local dns_name="$1"
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - update_route53_private - dry run set${NC}"
        return
    fi
    for x in "api-int" "api"; do
        cat << EOF > /tmp/route53_policy
        {
            "Changes": [
              {
                "Action": "UPSERT",
                "ResourceRecordSet": {
                  "Name": "$x.$dns_name",
                  "Type": "A",
                  "TTL": 300,
                  "ResourceRecords": [
                    {
                      "Value": "$private_instance_ip"
                    }
                  ]
                }
              }
            ]
          }
EOF

        aws route53 change-resource-record-sets \
        --region=${region} \
        --hosted-zone-id $(echo ${private_hosted_zone} | sed 's/\/hostedzone\///g') \
        --change-batch file:///tmp/route53_policy
        if [ "$?" != 0 ]; then
            echo -e "🕱${RED}Failed - could not associate eip $eip with instance $instance_id ?${NC}"
            exit 1
        else
            echo -e "${GREEN} -> associate_eip [ $eip, $eip_alloc, $instance_id ] OK${NC}"
        fi
    done
}

find_nat_gateways() {
    local tag_value="$1"
    nat_gateways=$(aws ec2 describe-nat-gateways --region=${region} \
    --query="NatGateways[].NatGatewayId" \
    --filter "Name=tag-value,Values=$tag_value" "Name=vpc-id,Values=${vpc_id}" \
    --output text)
    if [ -z "$nat_gateways" ]; then
        echo -e "💀${ORANGE}Warning - could not find nat gateways for tag: $tag_value in vpc $vpcid - continuing, they may have been deleted already ?${NC}"
    else
        echo "🌴 NatGateways set to $nat_gateways"
    fi
}

delete_nat_gateways() {
    set -o pipefail
    if [ ! -z "$nat_gateways" ]; then
        for x in $nat_gateways; do
            aws ec2 delete-nat-gateway \
            ${DRYRUN:---dry-run} \
            --nat-gateway-id $x \
            --region=${region} 2>&1 | tee /tmp/aws-error-file
            if [ "$?" != 0 ]; then
                if egrep -q "DryRunOperation" /tmp/aws-error-file; then
                    echo -e "${GREEN}Ignoring - delete_nat_gateways - dry run set${NC}"
                else
                    echo -e "🕱${RED}Failed - could not delete nat gateway $x ?${NC}"
                    exit 1
                fi
            else
                echo -e "${GREEN} -> delete_nat_gateways [ $x ] OK${NC}"
            fi
        done
    fi
    set +o pipefail
}

wait_for_nat_gateway_delete() {
    set -o pipefail
    if [ ! -z "$nat_gateways" ]; then
        aws ec2 wait nat-gateway-deleted \
        ${DRYRUN:---dry-run} \
        --nat-gateway-id $x \
        --region=${region} 2>&1 | tee /tmp/aws-error-file
        if [ "$?" != 0 ]; then
            if egrep -q "DryRunOperation" /tmp/aws-error-file; then
                echo -e "${GREEN}Ignoring - wait_for_nat_gateway_delete - dry run set${NC}"
            else
                echo -e "🕱${RED}Failed - waiting for nat gateways to delete failed - $nat_gateways ?${NC}"
                exit 1
            fi
        else
            echo -e "${GREEN} -> wait_for_nat_gateway_delete [ $nat_gateways ] OK${NC}"
        fi
    fi
    sleep 30 # try to avoid auth failure when we release eip next
    set +o pipefail
}

release_eips() {
    local tag_value="$1"
    IFS=$'\n' read -d '' -r -a lines < <(aws ec2 describe-addresses \
    --region=${region} \
    --query "Addresses[].[PublicIp,AllocationId]" \
    --filters "Name=tag-value,Values=$tag_value" \
    --output text)
    if [ ! -z "$lines" ]; then
        set -o pipefail
        for line in "${lines[@]}"; do 
            read -r ip alloc_id <<< "$line"
            aws ec2 release-address \
            ${DRYRUN:---dry-run} \
            --region=${region} \
            --allocation-id $alloc_id 2>&1 | tee /tmp/aws-error-file
            if [ "$?" != 0 ]; then
                if egrep -q "DryRunOperation" /tmp/aws-error-file; then
                    echo -e "${GREEN}Ignoring - release_eips - dry run set${NC}"
                else
                    echo -e "🕱${RED}Failed - could not release eip $ip $alloc_id ?${NC}"
                    exit 1
                fi
            else
                echo -e "${GREEN} -> release_eips [ $ip, $alloc_id ] OK${NC}"
            fi
        done
        set +o pipefail
    else
        echo -e "💀${ORANGE}Warning - could not find any eips to release - continuing, they may have been deleted already ?${NC}"
    fi
}

find_network_load_balancers() {
    network_load_balancers=$(aws elbv2 describe-load-balancers --region=${region} \
    --query="LoadBalancers[].LoadBalancerArn" \
    --output text)
    if [ -z "$network_load_balancers" ]; then
        echo -e "💀${ORANGE}Warning - could not find load balancers - continuing, they may have been deleted already ?${NC}"
    else
        echo "🌴 NetworkLoadBalancers set to $network_load_balancers"
    fi
}

delete_network_load_balancers() {
    if [ -z "$DRYRUN" ]; then
        echo -e "${GREEN}Ignoring - delete_load_balancers - dry run set${NC}"
        return
    fi
    if [ ! -z "$network_load_balancers" ]; then
        for x in $network_load_balancers; do
            aws elbv2 delete-load-balancer \
            --region=${region} \
            --load-balancer-arn $x
            if [ "$?" != 0 ]; then
                echo -e "🕱${RED}Failed - could not delete load balancer $x ?${NC}"
                exit 1
            else
                echo -e "${GREEN} -> delete_load_balancers [ $x ] OK${NC}"
            fi
        done
    fi
}

find_router_lb() {
    router_load_balancer=$(aws elb describe-load-balancers \
    --region=${region} \
    --query="LoadBalancerDescriptions[].LoadBalancerName" \
    --output text)
    if [ -z "$router_load_balancer" ]; then
        echo -e "🕱${RED}Warning - could not find router load balancer ?${NC}"
        exit 1
    else
        echo "🌴 RouterLoadBalancer set to $router_load_balancer"
    fi
}

associate_router_eip() {
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
            echo -e "${GREEN} -> associate_router_eip [ $router_load_balancer, $instance_id ] OK${NC}"
        fi
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

# fixme
#delete_target_groups() {
    #aws elbv2 describe-target-groups
#}

# do it all
all() {
    echo "🌴 BASE_DOMAIN set to $BASE_DOMAIN"
    echo "🌴 CLUSTER_NAME set to $CLUSTER_NAME"

    # find ids
    find_region
    find_instance_id "$CLUSTER_NAME-*-master-0"
    find_vpc_id "$CLUSTER_NAME-*-vpc"
    find_master_sg "$CLUSTER_NAME-*-master-sg"

    # updates
    update_master_sg
    find_or_allocate_eip
    associate_eip
    
    find_public_route_table "$CLUSTER_NAME-*-public"
    find_private_route_tables "$CLUSTER_NAME-*-private-*"
    update_private_routes

    find_public_route53_hostedzone "$BASE_DOMAIN"
    update_route53_public "$CLUSTER_NAME.$BASE_DOMAIN"
    find_instance_private_ip_address
    find_private_route53_hostedzone "$CLUSTER_NAME.$BASE_DOMAIN"
    update_route53_private "$CLUSTER_NAME.$BASE_DOMAIN"

    find_nat_gateways "$CLUSTER_NAME-*-nat-*"
    delete_nat_gateways
    wait_for_nat_gateway_delete
    release_eips "$CLUSTER_NAME-*-eip-*"

    find_network_load_balancers
    delete_network_load_balancers
    restart_instance

    find_router_lb
    associate_router_eip

    wait_for_openshift_api
}

usage() {
  cat <<EOF 2>&1
usage: $0 [ -d -b <BASE_DOMAIN> -c <CLUSTER_NAME> ]

Adjust SNO instance networking. By default dry-run is ON ! You must set -d to doIt™️
        -d     do it ! no dry run - else we print out whats going to happen and any non desructive lookups

Optional arguments if not set in environment:

        -b     BASE_DOMAIN - openshift base domain (or export BASE_DOMAIN env var)
        -c     CLUSTER_NAME - openshift cluster name (or export CLUSTER_NAME env var)

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

EOF
  exit 1
}

while getopts b:c:d opt; do
  case $opt in
    b)
      BASE_DOMAIN=$OPTARG
      ;;
    c)
      CLUSTER_NAME=$OPTARG
      ;;
    d)
      DRYRUN="--no-dry-run"
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

all

echo -e "\n🌻${GREEN}AWS SNO Reconfigured OK.${NC}🌻\n"
exit 0
