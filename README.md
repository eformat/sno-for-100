# sno-for-100

Prerequisites:

- [AWS command line](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [AWS account login](https://aws.amazon.com/console/)
- [OpenShift pull secret](https://cloud.redhat.com/openshift/install/pull-secret)
- [OpenShift command line](https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/)

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
    openshift-install create ignition-configs --dir=cluster
    openshift-install create manifests --dir=cluster
    openshift-install create cluster --dir=cluster
    ```

3. Export Env.Vars

    ```bash
    export AWS_PROFILE=rhpds
    export BASE_DOMAIN=sandbox1272.opentlc.com
    export CLUSTER_NAME=hivec
    ```

4. Get our SNO InstanceId

    ```bash
    aws ec2 describe-instances \
    --query "Reservations[].Instances[].InstanceId" \
    --filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" \
    --output text
    ```

5. Convert SNO to SPOT

    ```bash
    ec2-spot-converter --generate-dynamodb-table
    ec2-spot-converter --stop-instance --instance-id <instance_id>
    ```

6. Adjust AWS Objects

    Dry run (no changes, just perform lookups). Do this first to check, as the script may be over select.

    ```bash
    ./adjust-single-node.sh
    ```

    DoIt !

    ```bash
    ./adjust-single-node.sh -d
    ```

## Fix the internal node instance references

1. Export Env.Vars

    ```bash
    export AWS_PROFILE=rhpds
    export BASE_DOMAIN=sandbox1272.opentlc.com
    export CLUSTER_NAME=hivec
    export KUBEADMIN_PASSWORD=rQEtP-kZtcM-jzyu8-MfVhX
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
