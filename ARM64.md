# ARM64

You can install arm64 based OpenShift as well using and ARM based jumphost.

I used [the instructions from here](https://www.redhat.com/sysadmin/vm-arm64-fedora) to spin up an arm64 based vm on fedora.

```bash
dnf install qemu-system-aarch64
cd /var/lib/libvirt/images
wget https://download.fedoraproject.org/pub/fedora-secondary/releases/39/Spins/aarch64/images/Fedora-Minimal-39-1.5.aarch64.raw.xz -O f39.xz && unxz f39.xz

virt-install -v --name fedora-39-aarch64 --ram 4096 \
 --disk path=f39,cache=none --nographics --os-variant fedora39  \
 --import --arch aarch64 --vcpus 4
```

Install the prerequisites in your vm.

```bash
dnf install yq tar python-pip wget unzip
pip install awscli --user
```

And you should be good to go !

```bash
export INSTANCE_TYPE=m7g.2xlarge
```
