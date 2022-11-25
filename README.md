# sno-for-100

## Prerequisites:

- [AWS command line](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [AWS account login](https://aws.amazon.com/console/)
- [OpenShift pull secret](https://cloud.redhat.com/openshift/install/pull-secret)
- [OpenShift command line and installer](https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/)
- [ec2-spot-converter script](https://github.com/jcjorel/ec2-spot-converter/)

### Generate DynamoDB Table

This step needs to be performed once in each region and account that you will be provisioning instances.
It serves as a temporal tracking table for the tool.

```bash
export AWS_PROFILE=rhpds
export AWS_REGION=ap-southeast-1
ec2-spot-converter --generate-dynamodb-table
```

## Install and Adjust the SNO instance

This portion performs a SNO install and then moves it to the public subnets.
It will remove the unneeded portions of the networking infrastructure.

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
    export KUBECONFIG=<path to your>/cluster/auth/kubeconfig 
    export CLUSTER_NAME=my-cluster
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

5. Check

    It may take a couple of minutes for SNO to settle down (authentication, ingress operators become available).
    You should now be able to login to your cluster OK. Check `oc get co` to make sure cluster operators are healthy.
    Check the router ELB has the instance associated (this will be temporary until you run the fix instance id script).

## Convert SNO to SPOT pricing

This portion does the actual conversion to persistent spot instance pricing.
    
```bash
export INSTANCE_ID=$(aws ec2 describe-instances \
--query "Reservations[].Instances[].InstanceId" \
--filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" "Name=instance-state-name,Values=running" \
--output text)
```

```bash
ec2-spot-converter --stop-instance \
--instance-id $INSTANCE_ID
```

There are several other options for the tool not used here but which could be invoked:

* max spot price
* change instance type
* delete the AMI when it completes
* change the encryption key for the root volume
* convert from spot back to on-demand

Documentation of the settings and how to use them are on the ec2-spot-converter tool's homepage.

## Fix the internal node instance references

After converting to spot, there are a few references to the old instance ID in the cluster which must be remedied so the operators function correctly for the life of the cluster.

1. Export Env.Vars

    ```bash
    export AWS_PROFILE=rhpds
    export AWS_REGION=ap-southeast-1
    export BASE_DOMAIN=sandbox.acme.com
    export CLUSTER_NAME=my-cluster
    export KUBECONFIG=<path to your>/cluster/auth/kubeconfig 
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

## Delete SNO instance

1. If you no longer need your instance, to remove all related aws objects just run.

    ```bash
    openshift-install destroy cluster --dir=cluster
    ```
