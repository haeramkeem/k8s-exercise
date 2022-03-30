#!/usr/bin/env bash

# Check node type
if [[ $1 != "--master" ]] && [[ $1 != "--worker" ]]
then
    echo "Please specify the node type: --master or --worker"
    exit 1
fi

# Kubernetes requires the disabling of the partition swapping
#   swapoff -a to disable swapping
swapoff -a
#   sed to comment the swap partition in /etc/fstab
sed -i.bak -r 's/(.+ swap .+)/#\1/' /etc/fstab

# Set SELinux in permissive mode (effectively disabling it)
#   SELinux means Security Enhanced Linux which is security-enhanced version of linux kernel
#       In RHEL/CentOS, SELinux is installed and running on 'enforce' mode by default
#       The 'enforce' mode rejects the insecured operations
#       And 'permissive' mode allows the insecured operations but leave the audit to the log
#       By 'disable' mode, u can disable the SELinux
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# Use iptables and br_netfilter kernel module for IPv4 & IPv6 routing table
#   RHEL/CentOS 7 have reported traffic issues being routed incorrectly due to iptables bypassed
cat <<EOF > /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
modprobe br_netfilter
sysctl --system

# Set local DNS - this will make communication between nodes with hostname instead of IP
MASTER_IP=$(grep "m1-k8s:" meta.yaml | awk '{print $2}')
echo "$MASTER_IP m1-k8s" >> /etc/hosts
for (( i=1; i<=$(grep "worker-count:" meta.yaml | awk '{print $2}'); i++  ))
do
    echo "192.168.1.10$i w$i-k8s" >> /etc/hosts
done

# Install Docker
echo "----- BEGIN DOCKER INSTALL -----"
rpm -ivh --replacefiles --replacepkgs ./rpms/docker/*.rpm
rm -fr ./rpms/docker # Remove installation files 

#   Configure cgroup driver and insecure docker registry
mkdir -pv /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ]
}
EOF

systemctl enable --now docker.service
echo "Docker installed"

# Load all images
echo "----- LOAD IMAGES -----"
FILES="./images/*.tar"
for f in $FILES
do
    docker load < $f
    rm -rf $f # Remove image files
done

# Install Kubernetes
echo "----- BEGIN K8S INSTALL -----"
rpm -ivh --replacefiles --replacepkgs ./rpms/k8s/*.rpm
rm -rf ./rpms/k8s
systemctl enable --now kubelet
echo "K8s installed"

# k8s cluster token
TOKEN=$(grep "token:" meta.yaml | awk '{print $2}')

# docker registry certificate path
REG_IP=$(grep "reg-ip:" meta.yaml | awk '{print $2}')
REG_PORT=$(grep "reg-port:" meta.yaml | awk '{print $2}')
certs=/etc/docker/certs.d/$REG_IP:$REG_PORT
mkdir -pv $certs

# config for master node only
if [[ $1 = "--master" ]]
then
    # firewall configuration
    firewall-cmd --permanent --add-port={6443,2379,2380,10250,10251,10252}/tcp
    firewall-cmd --reload

    # init kubernetes cluster
    kubeadm init\
        --token $TOKEN\
        --token-ttl 0 \
        --pod-network-cidr=$(grep "cidr:" meta.yaml | awk '{print $2}')\
        --apiserver-advertise-address=$MASTER_IP

    # copy configuration
    mkdir -pv $HOME/.kube
    cp -irv /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    # config for kubernetes's network (Calico)
    kubectl apply -f ./manifests/calico.yaml

    # install docker registry
    #   image saving dir
    mkdir -pv /registry-image

    #   cert for server
    mkdir -pv /etc/docker/certs

    #   modify `tls.csr`
    sed -i "s/IPADDR/$REG_IP/g" tls.csr

    #   generate cert
    openssl req\
        -x509\
        -config $(dirname "$0")/tls.csr\
        -nodes\
        -newkey rsa:4096\
        -keyout tls.key\
        -out tls.crt\
        -days 365\
        -extensions v3_req

    #   copy cert
    cp -irv tls.crt $certs
    mv tls.* /etc/docker/certs
    cp -irv /etc/docker/certs/tls.csr .

    #   run registry
    docker run -d\
        --restart=always\
        --name registry\
        -v /etc/docker/certs:/docker-in-certs:ro\
        -v /registry-image:/var/lib/registry\
        -e REGISTRY_HTTP_ADDR=0.0.0.0:443\
        -e REGISTRY_HTTP_TLS_CERTIFICATE=/docker-in-certs/tls.crt\
        -e REGISTRY_HTTP_TLS_KEY=/docker-in-certs/tls.key\
        -p $REG_PORT:443\
        registry:2

fi

# config for worker nodes
if [[ $1 = "--worker" ]]
then
    # firewall configuration
    firewall-cmd --permanent --add-port={10250,30000-32767}/tcp
    firewall-cmd --reload

    # join kubernetes cluster
    kubeadm join\
        --token $TOKEN\
        --discovery-token-unsafe-skip-ca-verification $MASTER_IP:6443\

    # get docker registry cert
    #   use openssl for fetching registry cert
    openssl s_client -showcerts -connect $REG_IP:$REG_PORT\
        </dev/null 2>/dev/null|openssl x509 -outform PEM >$certs/tls.crt

fi
