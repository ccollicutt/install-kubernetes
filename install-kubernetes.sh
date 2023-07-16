#!/bin/bash

# this script installs kubernetes on Ubuntu 22.04

set -eE

#
# errors and cleanup
#

# NOTE: A lot of grouped output calls are used here:
#
# {
#   some_command
#   some_other_command
# } > do something with outout
#
# This causes problems catting the logfile on an error, so there is some
# magic done there ala:
# https://unix.stackexchange.com/questions/448323/trap-and-collect-script-output-input-file-is-output-file-error

function err_report() {
  echo "Error on line $(caller)" >&2
  exec >&3 2>&3 3>&-
  cat $LOG_FILE
  cleanup_tmp
}
trap err_report ERR

function cleanup_tmp(){
  rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

### help
function show_help(){
    echo "USAGE:"
    echo "On a control plane node use the '-c' option"
    echo "$0 -c"
    echo "On a worker node, run with no options"
    echo "$0"
    echo "For a single node, control plane and worker together, run with the '-s' option"
    echo "$0 -s"
    echo "For verbose output, run with the '-v' option"
    echo "$0 -v"
}

### check if Ubuntu 22.04 Jammy
function check_linux_distribution(){
  echo "Checking Linux distribution"
  source /etc/lsb-release
  if [ "$DISTRIB_RELEASE" != "${UBUNTU_VERSION}" ]; then
      echo "ERROR: This script only works on Ubuntu 22.04"
      exit 1
  fi
}

### disable linux swap and remove any existing swap partitions
function disable_swap(){
  echo "Disabling swap"
  {
    swapoff -a
    sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab
  } 3>&2 >> $LOG_FILE 2>&1
}

### remove packages
function remove_packages(){
  echo "Removing packages"
  {
    # remove packages
    apt-mark unhold kubelet kubeadm kubectl kubernetes-cni || true
    # moby-runc is on github runner? have to remove it
    apt-get remove -y moby-buildx moby-cli moby-compose moby-containerd moby-engine moby-runc || true
    apt-get autoremove -y
    apt-get remove -y docker.io containerd kubelet kubeadm kubectl kubernetes-cni || true
    apt-get autoremove -y
    systemctl daemon-reload
  } 3>&2 >> $LOG_FILE 2>&1 
}

### install required packages
function install_packages(){
  echo "Installing required packages"
  {
    apt-get update
    apt-get install -y \
      apt-transport-https \
      ca-certificates \
      curl \
      gnupg \
      lsb-release \
      software-properties-common \
      wget \
      jq
  } 3>&2 >> $LOG_FILE 2>&1
}

### install kubernetes packages
function install_kubernetes_packages(){
  echo "Installing Kubernetes packages"
  cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
  {
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    apt-get update
    apt-get install -y \
      containerd \
      kubelet=${KUBE_VERSION}-00 \
      kubeadm=${KUBE_VERSION}-00 \
      kubectl=${KUBE_VERSION}-00 \
      kubernetes-cni
    apt-mark hold  \
      kubelet \
      kubeadm \
      kubectl \
      kubernetes-cni
  } 3>&2 >> $LOG_FILE 2>&1
}

### install containerd from binary over apt installed version
function install_containerd(){
  echo "Installing containerd"
  # NOTE(curtis): to get containerd 1.7 deploy from tar file instead of apt
  # think latest app is 1.6.12 
  {
    pushd ${TMP_DIR}
      wget -q https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
      tar xvf containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
      systemctl stop containerd
      mv bin/* /usr/bin
      rm -rf bin containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
    popd
    systemctl unmask containerd
    systemctl start containerd
  } 3>&2 >> $LOG_FILE 2>&1
}

### set required sysctl params, these persist across reboots
function configure_system(){
  echo "Configuring system"
  cat <<EOF > /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
  cat <<EOF > /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  {
    sudo modprobe overlay
    sudo modprobe br_netfilter
    sudo sysctl --system
  } 3>&2 >> $LOG_FILE 2>&1
}

### containerd
function configure_containerd(){
  echo "Configuring containerd"
  sudo mkdir -p /etc/containerd 3>&2 >> $LOG_FILE 2>&1
### config.toml
cat > /etc/containerd/config.toml <<EOF
disabled_plugins = []
imports = []
oom_score = 0
plugin_dir = ""
required_plugins = []
root = "/var/lib/containerd"
state = "/run/containerd"
version = 2

[plugins]

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      base_runtime_spec = ""
      container_annotations = []
      pod_annotations = [] 
      privileged_without_host_devices = false
      runtime_engine = ""
      runtime_root = ""
      runtime_type = "io.containerd.runc.v2"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        BinaryName = ""
        CriuImagePath = ""
        CriuPath = ""
        CriuWorkPath = ""
        IoGid = 0
        IoUid = 0
        NoNewKeyring = false
        NoPivotRoot = false
        Root = ""
        ShimCgroup = ""
        SystemdCgroup = true
EOF
}

### crictl uses containerd as default
function configure_crictl(){
echo "Configuring crictl"
cat <<EOF > /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF
}

### kubelet should use containerd
function configure_kubelet(){
echo "Configuring kubelet"
cat <<EOF > /etc/default/kubelet
KUBELET_EXTRA_ARGS="--container-runtime-endpoint unix:///run/containerd/containerd.sock"
EOF
}

### start services
function start_services(){
  echo "Starting services"
  {
    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd
    # maybe this never worked...
    # kubelet won't start without /var/lib/kubelet/config.yaml which won't exist yet,
    # not until kubeadm init is run afaik
    systemctl enable kubelet && systemctl start kubelet
  } 3>&2 >> $LOG_FILE 2>&1
}

### install calico as the CNI
function install_cni(){
  # need to deploy two manifests for calico to work
  echo "Installing Calico CNI"
  for manifest in tigera-operator custom-resources; do
    echo "==> Installing Calico ${manifest}"
    kubectl create -f ${CALICO_URL}/${manifest}.yaml 3>&2 >> $LOG_FILE 2>&1
  done
}

function install_metrics_server(){
  echo "Installing metrics server"
  {
    kubectl apply -f manifests/metrics-server.yaml
    # TODO: wait for metrics server to be ready
  } 3>&2 >> $LOG_FILE 2>&1
}

### initialize the control plane
function kubeadm_init(){
  echo "Initializing the Kubernetes control plane"
  {
    kubeadm init \
    --kubernetes-version=${KUBE_VERSION} \
    --ignore-preflight-errors=NumCPU \
    --skip-token-print \
    --pod-network-cidr 192.168.0.0/16 
  } 3>&2 >> $LOG_FILE 2>&1
}

### wait for nodes to be ready
function wait_for_nodes(){
  echo "Waiting for nodes to be ready..."
  {
    kubectl wait \
      --for=condition=Ready \
      --all nodes \
      --timeout=180s
  } 3>&2 >> $LOG_FILE 2>&1
  echo "==> Nodes are ready"
}

### configure kubeconfig for root and ubuntu
function configure_kubeconfig(){
  echo "Configuring kubeconfig for root and ubuntu users"
  {
    # NOTE(curtis): sometimes ubuntu user won't exist, so we don't care if this fails
    rm /root/.kube/config || true
    rm /home/ubuntu/.kube/config || true
    mkdir -p /root/.kube
    mkdir -p /home/ubuntu/.kube || true
    cp -i /etc/kubernetes/admin.conf /root/.kube/config
    cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config || true
    chown ubuntu:ubuntu /home/ubuntu/.kube/config || true
  } 3>&2 >> $LOG_FILE 2>&1
}

### check if worker services are running
function check_worker_services(){
  echo "Check worker services"
  # Really until it's added to the kubernetes cluster only containerd
  # will be running...
  {
    echo "==> Checking containerd"
    systemctl is-active containerd
  } 3>&2 >> $LOG_FILE 2>&1
}

### taint the node so that workloads can run on it, assuming there is only
### one node in the cluster
function configure_as_single_node(){
  echo "Configuring as a single node cluster"
  {
    # this is a single node cluster, so we need to taint the master node
    # so that pods can be scheduled on it
    kubectl taint nodes --all \
      node-role.kubernetes.io/control-plane:NoSchedule-
    echo "==> Sleeping for 10 seconds to allow taint to take effect..."
    sleep 10 # wait for the taint to take effect
  } 3>&2 >> $LOG_FILE 2>&1
}

### test if an nginx pod can be deployed to validate the cluster
function test_nginx_pod(){
  echo "Deploying test nginx pod"
  {
    # deploy a simple nginx pod
    kubectl run --image nginx --namespace default nginx
    # wait for all pods to be ready
    kubectl wait \
      --for=condition=Ready \
      --all pods \
      --namespace default \
      --timeout=180s
    # delete the nginx pod
    kubectl delete pod nginx --namespace default
  } 3>&2 >> $LOG_FILE 2>&1
}

### doublecheck the kubernetes version that is installed
function test_kubernetes_version() {
  echo "Checking Kubernetes version..."
  kubectl_version=$(kubectl version -o json)

  # use gitVersion
  client_version=$(echo "$kubectl_version" | jq '.clientVersion.gitVersion' | tr -d '"')
  server_version=$(echo "$kubectl_version" | jq '.serverVersion.gitVersion' | tr -d '"')

  echo "==> Client version: $client_version"
  echo "==> Server Version: $server_version"

  # check if kubectl and server are the same version
  if [[ "$client_version" != "$server_version" ]]; then
    echo "==> Client and server versions differ, exiting..."
    exit 1
  fi

  # check if what we asked for was what we got
  local kube_version="v${KUBE_VERSION}"
  if [[ "$kube_version" == "$server_version" ]]; then
    echo "==> Requested KUBE_VERSION matches the server version."
  else
    echo "==> Requested KUBE_VERSION does not match the server version, exiting..."
    exit 1
  fi

}



#
# MAIN
#

### run the whole thing
function run_main(){
  echo "Starting install..."
  echo "==> Logging all output to $LOG_FILE"
  check_linux_distribution
  disable_swap
  remove_packages
  install_packages
  install_kubernetes_packages
  install_containerd
  configure_containerd
  configure_system
  configure_crictl
  configure_kubelet
  start_services

  # only run this on the control plane node
  if [[ "${CONTROL_NODE}" == "true" || "${SINGLE_NODE}" == "true" ]]; then
    echo "Configuring control plane node..."
    kubeadm_init
    configure_kubeconfig
    install_cni
    wait_for_nodes
    # now  test what was installed
    test_kubernetes_version
    install_metrics_server
    if [[ "${SINGLE_NODE}" == "true" ]]; then
      echo "Configuring as a single node cluster"
      configure_as_single_node
      test_nginx_pod
    fi
    echo "Install complete!"

    echo
    echo "### Command to add a worker node ###"
    kubeadm token create --print-join-command --ttl 0
  else
    # is a worker node
    check_worker_services
    echo "Install complete!"
    echo
    echo "### To add this node as a worker node ###"
    echo "Run the below on the control plane node:"
    echo "kubeadm token create --print-join-command --ttl 0"
    echo "and execute the output on the worker nodes"
    echo
  fi
}

# assume it's a worker node by default
WORKER_NODE=true
CONTROL_NODE=false
SINGLE_NODE=false
VERBOSE=false
UBUNTU_VERSION=22.04

# software versions
KUBE_VERSION=1.27.3
CONTAINERD_VERSION=1.7.0
CALICO_VERSION=3.25.0
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/"

# create a temp dir to store logs
TMP_DIR=$(mktemp -d -t install-kubernetes-XXXXXXXXXX)
readonly TMP_DIR
LOG_FILE=${TMP_DIR}/install.log

while getopts "h?cvs" opt; do
  case "$opt" in
    h|\?)
      show_help
      exit 0
      ;;
    c)  CONTROL_NODE=true
        WORKER_NODE=false
      ;;
    v) VERBOSE=true
      ;;
    s) SINGLE_NODE=true
  esac
done

# only run main if running from scripts not testing with bats
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  run_main
  # print the log file if verbose, though it will be after all the commands run
  if [ "${VERBOSE}" == "true" ]; then
    echo
    echo "### Log file ###"
    cat $LOG_FILE
  fi
fi