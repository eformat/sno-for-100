## Add Extra Storage for you SNO on SPOT

To keep things cheap, I use a 200GB gp3 volume and configure the OpenShift LVM Operator to use it as the default dynamic Storage Class for my SNO instance.

1. Get your aws instance id.

    ```bash
    export INSTANCE_ID=$(aws ec2 describe-instances \
    --query "Reservations[].Instances[].InstanceId" \
    --filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" "Name=instance-state-name,Values=running" \
    --output text)
    ```

2. Get the aws zone for your instance id.

    ```bash
    export AWS_ZONE=$(aws ec2 describe-instances \
    --query "Reservations[].Instances[].Placement.AvailabilityZone" \
    --filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" "Name=instance-state-name,Values=running" \
    --output text)
    ```

3. Create the volume.

    ```bash
    vol=$(aws ec2 create-volume \
    --availability-zone ${AWS_ZONE} \
    --volume-type gp3 \
    --size 200 \
    --region=${AWS_DEFAULT_REGION})
    ```

4. Attach the volume to your instance.

    ```bash
    aws ec2 attach-volume \
    --volume-id $(echo ${vol} | jq -r '.VolumeId') \
    --instance-id ${INSTANCE_ID} \
    --device /dev/sdf
    ```

5. You should see the successful attachment output printed.

6. Next we are going to configure the LVM Operator to use this disk. Create a namespace.

    ```bash
    cat <<EOF | oc apply -f-
    kind: Namespace
    apiVersion: v1
    metadata:
      name: openshift-storage
    EOF
    ```

7. Create an operator group.

    ```bash
    cat <<'EOF' | oc apply -f-
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
      name: operator-storage
      namespace: openshift-storage
    spec:
      targetNamespaces:
      - openshift-storage
    EOF
    ```

8. Create the operator subscription.

    ```bash
    cat <<EOF | oc apply -f-
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      labels:
        operators.coreos.com/odf-lvm-operator.openshift-storage: ''
      name: odf-lvm-operator
      namespace: openshift-storage
    spec:
      channel: stable-4.11
      installPlanApproval: Automatic
      name: odf-lvm-operator
      source: redhat-operators
      sourceNamespace: openshift-marketplace
    EOF
    ```

9. Wait until the operator has installed successfully.

10. Configure the LVMCluster. By default this will use the gp3 disk device we configured earlier.

    ```bash
    cat <<EOF | oc apply -f-
    apiVersion: lvm.topolvm.io/v1alpha1
    kind: LVMCluster
    metadata:
      name: sno-lvm
      namespace: openshift-storage
    spec:
      storage:
        deviceClasses:
          - name: vgsno
            thinPoolConfig:
              name: thin-pool-1
              overprovisionRatio: 10
              sizePercent: 90
    EOF
    ```

11. Make the LVM storage the default storage class.

    ```bash
    oc annotate sc/odf-lvm-vgsno storageclass.kubernetes.io/is-default-class=true
    ```

    Remove old defaults (the default SC varies depending on OpenShift Cluster version)

    ```bash
    oc annotate sc/gp2 storageclass.kubernetes.io/is-default-class-
    oc annotate sc/gp3-csi storageclass.kubernetes.io/is-default-class-
    ```
