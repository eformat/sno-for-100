# sno-for-100

Create Openshift SNO AWS Config

```bash
mkdir -p cluster
# vi install-config.yaml
# update: pullSecret, sshKey, region, type, rootVolume: size, metadata: name, baseDomain
cp install-config.yaml cluster/
```

Install OpenShift

```bash
openshift-install create ignition-configs --dir=cluster
openshift-install create manifests --dir=cluster
openshift-install create cluster --dir=cluster
```

Export Env.Vars

```bash
export BASE_DOMAIN=sandbox1272.opentlc.com
export CLUSTER_NAME=hivec
```

Get our SNO InstanceId

```bash
# get our instance_id
aws ec2 describe-instances \
--query "Reservations[].Instances[].InstanceId" \
--filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" \
--output text
```

Convert SNO to SPOT

```bash
# creates dynamodb in profile region (~/.aws/config)
ec2-spot-converter --generate-dynamodb-table
ec2-spot-converter --stop-instance --instance-id <instance_id>
```

Adjust AWS Objects

```bash
./adjust-single-node.sh
```
