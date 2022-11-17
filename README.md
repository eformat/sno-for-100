# sno-for-100

Prerequisites:

- [AWS command line](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [AWS account login](https://aws.amazon.com/console/)
- [OpenShift pull secret](https://cloud.redhat.com/openshift/install/pull-secret)
- [OpenShift command line and installer](https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/)
- [ec2-spot-converter script](https://pythonawesome.com/a-tool-to-convert-aws-ec2-instances-back-and-forth-between-on-demand/)

```bash
TOOL_VERSION=`curl https://raw.githubusercontent.com/jcjorel/ec2-spot-converter/master/VERSION.txt`
curl https://raw.githubusercontent.com/jcjorel/ec2-spot-converter/master/releases/ec2-spot-converter-${TOOL_VERSION} -o ec2-spot-converter
chmod u+x ec2-spot-converter
export AWS_PROFILE=rhpds
export AWS_REGION=ap-southeast-1
ec2-spot-converter --generate-dynamodb-table
```

## Install and Adjust the SNO instance

1. Create Openshift SNO AWS Config

    ```bash
    mkdir -p cluster
    # vi install-config.yaml
    # update: pullSecret, sshKey, region, type, rootVolume: size, metadata: name, baseDomain
    cp install-config.yaml cluster/
    ```

2. Install OpenShift

    ```bash
    export AWS_PROFILE=rhpds
    export AWS_REGION=ap-southeast-1
    openshift-install create cluster --dir=cluster
    ```

3. Export Env.Vars

    ```bash
    export CLUSTER_NAME=hivec
    export BASE_DOMAIN=sandbox.acme.com
    ```

4. Adjust AWS Objects

    Dry run (no changes, just perform lookups). Do this first to check output, as the script may over select.

    ```bash
    ./adjust-single-node.sh
    ```

    DoIt !

    ```bash
    ./adjust-single-node.sh -d
    ```

5. Convert SNO to SPOT

    ```bash
    export INSTANCE_ID=$(aws ec2 describe-instances \
    --query "Reservations[].Instances[].InstanceId" \
    --filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" \
    --output text)
    
    ec2-spot-converter --stop-instance --instance-id $INSTANCE_ID
    ```

6. Check

    It may take a couple of minutes for SNO to settle after restarting (authentication, ingress operators become available).
    You should now be able to login to your cluster OK. Check `oc get co` to make sure cluster operators are healthy.
    Check the router ELB has the instance associated (this will be temporary until you run the fix instance id script).

## Fix the internal node instance references

1. Export Env.Vars

    ```bash
    export AWS_PROFILE=rhpds
    export AWS_REGION=ap-southeast-1
    export BASE_DOMAIN=sandbox.acme.com
    export CLUSTER_NAME=my-cluster
    export KUBEADMIN_PASSWORD=your-random-kubeadmin-password
    ```

2. Fix internal node instance references

    Dry run (no changes, just perform lookups). Do this first to check.

    ```bash
    ./fix-instance-id.sh
    ```

    DoIt !

    ```bash
    ./fix-instance-id.sh -d
    ```

3. Check

    It may take a couple of minutes for SNO to settle after restarting (authentication, ingress operators become available).
    You should now be able to login to your cluster OK. Check `oc get co` to make sure cluster operators are healthy.
    Check the router ELB has the instance associated OK, this should be done automatically now by the node.
