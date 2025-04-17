
#!/bin/bash

set -e

CLUSTER_NAME=kind-gpu-sim
CONFIG_FILE=kind-gpu-config.yaml
REGISTRY_NAME=kind-registry
REGISTRY_PORT=5000
ECR_REGISTRY_IMAGE=public.ecr.aws/docker/library/registry:2

function start_local_registry() {
  echo " Starting local Docker registry from Amazon ECR Public..."
  running=$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo "false")
  if [ "$running" != "true" ]; then
    docker run -d --restart=always -p "${REGISTRY_PORT}:5000"       --name "${REGISTRY_NAME}" "${ECR_REGISTRY_IMAGE}"
  fi
}

function create_kind_cluster() {
  gpu_type="$1"
  echo " Creating kind cluster with 1 control-plane + 2 workers..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG_FILE}"

  echo " Connecting registry to kind network..."
  docker network connect "kind" "${REGISTRY_NAME}" || true

  echo " Detecting worker nodes dynamically..."
  worker_nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v control-plane)

  echo " Patching worker nodes with fake '${gpu_type}' GPUs..."
  for node in $worker_nodes; do
    echo "  Working on $node"
    kubectl label node "${node}" hardware-type=gpu --overwrite
    kubectl label node "${node}" node-role.kubernetes.io/worker="" --overwrite
    kubectl taint node "${node}" gpu=true:NoSchedule --overwrite

    if [ "$gpu_type" = "rocm" ]; then
      kubectl label node "${node}" rocm.amd.com/gpu.present=true --overwrite
      kubectl patch node "${node}" --type=json         -p='[{"op": "add", "path": "/status/capacity/amd.com~1gpu", "value":"2"}]'         --subresource=status
    elif [ "$gpu_type" = "nvidia" ]; then
      kubectl label node "${node}" nvidia.com/gpu.present=true --overwrite
      kubectl patch node "${node}" --type=json         -p='[{"op": "add", "path": "/status/capacity/nvidia.com~1gpu", "value":"2"}]'         --subresource=status
    fi
  done
}

function build_and_push_images() {
  gpu_type="$1"
  if [ "$gpu_type" = "nvidia" ]; then
    echo " Building NVIDIA device plugin locally..."
    if [ ! -d k8s-device-plugin-nvidia ]; then
      git clone https://github.com/NVIDIA/k8s-device-plugin.git k8s-device-plugin-nvidia
    fi
    cd k8s-device-plugin-nvidia
    docker build \
      --build-arg GOLANG_VERSION=1.21.6 \
      -t localhost:${REGISTRY_PORT}/nvidia-device-plugin:dev \
      -f deployments/container/Dockerfile \
      .
    docker push localhost:${REGISTRY_PORT}/nvidia-device-plugin:dev
    cd ..
    return
  fi

  echo " Building ROCm plugin images locally..."
  if [ ! -d k8s-device-plugin-rocm ]; then
    git clone https://github.com/RadeonOpenCompute/k8s-device-plugin.git k8s-device-plugin-rocm
  fi
  cd k8s-device-plugin-rocm
  echo " Patching Dockerfile to use Amazon ECR Public mirrors..."
  sed -i 's|FROM alpine:3.21.3|FROM public.ecr.aws/docker/library/alpine:3.21.3|' Dockerfile
  sed -i 's|FROM docker.io/golang:1.23.6-alpine3.21|FROM public.ecr.aws/docker/library/golang:1.23.6-alpine3.21|' Dockerfile
  sed -i 's|FROM golang:1.23.6-alpine3.21|FROM public.ecr.aws/docker/library/golang:1.23.6-alpine3.21|' Dockerfile
  docker build -t localhost:${REGISTRY_PORT}/amdgpu-dp:dev -f Dockerfile .
  docker push localhost:${REGISTRY_PORT}/amdgpu-dp:dev
  cd ..
}

function deploy_device_plugin() {
  gpu_type="$1"
  if [ "$gpu_type" = "rocm" ]; then
    deploy_rocm_plugin
  elif [ "$gpu_type" = "nvidia" ]; then
    deploy_nvidia_plugin
  else
    echo " Unknown GPU type: $gpu_type"
    exit 1
  fi
}

function deploy_rocm_plugin() {
  echo " Deploying AMD ROCm device plugin..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: amdgpu-device-plugin-daemonset
  namespace: kube-system
  labels:
    name: amdgpu-dp-ds
spec:
  selector:
    matchLabels:
      name: amdgpu-dp-ds
  template:
    metadata:
      labels:
        name: amdgpu-dp-ds
    spec:
      tolerations:
      - key: "gpu"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
      containers:
      - name: amdgpu-dp-ds
        image: localhost:${REGISTRY_PORT}/amdgpu-dp:dev
        securityContext:
          privileged: true
EOF
}

function deploy_nvidia_plugin() {
  echo " Deploying NVIDIA GPU device plugin..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
  labels:
    name: nvidia-device-plugin
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin
  template:
    metadata:
      labels:
        name: nvidia-device-plugin
    spec:
      tolerations:
      - key: gpu
        operator: Equal
        value: "true"
        effect: NoSchedule
      containers:
      - name: nvidia-device-plugin-ctr
        image: localhost:${REGISTRY_PORT}/nvidia-device-plugin:dev
        securityContext:
          privileged: true
        env:
        - name: FAIL_ON_INIT_ERROR
          value: "false"
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
          type: DirectoryOrCreate
EOF
}

function delete_cluster() {
  echo " Deleting kind cluster..."
  kind delete cluster --name "${CLUSTER_NAME}"
}

function usage() {
  echo "Usage: $0 {create [rocm|nvidia]|delete}"
  exit 1
}

case "$1" in
  create)
    gpu_type=${2:-rocm}
    start_local_registry
    create_kind_cluster "$gpu_type"
    build_and_push_images "$gpu_type"
    deploy_device_plugin "$gpu_type"
    echo " Simulated GPU Kind cluster is ready for '${gpu_type}'!"
    ;;
  delete)
    delete_cluster
    ;;
  *)
    usage
    ;;
esac
