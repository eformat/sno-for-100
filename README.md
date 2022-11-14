# sno-for-100

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

    Dry run (no changes, just perform lookups)

    ```bash
    ./adjust-single-node.sh
    ```

    DoIt !

    ```bash
    ./adjust-single-node.sh -d
    ```
