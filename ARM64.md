# ARM64

You can install arm64 based OpenShift by using an ARM based jumphost.

I used [the instructions from here](https://www.redhat.com/sysadmin/vm-arm64-fedora) to spin up an arm64 based vm on fedora.

```bash
dnf install qemu-system-aarch64
cd /var/lib/libvirt/images
wget https://dl.fedoraproject.org/pub/fedora/linux/releases/40/Spins/aarch64/images/Fedora-Minimal-40-1.14.aarch64.raw.xz -O f40.xz && unxz f40.xz

virt-install -v --name fedora-40-aarch64 --ram 4096 \
 --disk path=f40,cache=none --nographics --os-variant fedora40  \
 --import --arch aarch64 --vcpus 4
```

Install the prerequisites in your vm.

```bash
dnf install git yq tar python-pip wget unzip cloud-utils-growpart podman
pip install awscli --user
```

(Optional) grow jumphost vm size

```bash
qemu-img resize -f raw f40 +20G
growpart /dev/vda 3
resize2fs /dev/vda3
```

And you should be good to go !

```bash
export INSTANCE_TYPE=m7g.2xlarge
```
