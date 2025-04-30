#!/bin/bash
set -e

REGISTRY_PORT=5000

for arg in "$@"; do
  case "$arg" in
    --registry-port=*)
      REGISTRY_PORT="${arg#*=}"
      ;;
  esac
done

# --- Runtime detection ---
if command -v podman &>/dev/null; then
  echo "Using Podman as container runtime"
  CONTAINER_RUNTIME="podman"
  export KIND_EXPERIMENTAL_PROVIDER=podman
  export DOCKER_HOST=unix:///run/user/$UID/podman/podman.sock
  systemctl --user enable --now podman.socket || true
elif command -v docker &>/dev/null; then
  echo "Using Docker as container runtime"
  CONTAINER_RUNTIME="docker"
else
  echo "ERROR: Neither Docker nor Podman is installed." >&2
  exit 1
fi

cr() {
  "$CONTAINER_RUNTIME" "$@"
}

ECR_REGISTRY_IMAGE=public.ecr.aws/docker/library/registry:2
CLUSTER_NAME=kind-gpu-sim
CONFIG_FILE=kind-gpu-config.yaml
REGISTRY_NAME="kind-registry"

start_local_registry() {
  echo "Starting local registry on port ${REGISTRY_PORT}..."
  running=$(cr inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null || echo "false")
  if [ "$running" != "true" ]; then
    cr run -d --restart=always -p "${REGISTRY_PORT}:5000" \
      --name "$REGISTRY_NAME" \
      --network=kind \
      "$ECR_REGISTRY_IMAGE"
  else
    echo "Registry '${REGISTRY_NAME}' already running."
    cr network connect kind "$REGISTRY_NAME" 2>/dev/null || true
  fi
}

generate_kind_config() {
  rm -f "$CONFIG_FILE"
  cat > "$CONFIG_FILE" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
      endpoint = ["http://${REGISTRY_NAME}:5000"]
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
}

create_kind_cluster() {
  gpu_type="$1"
  generate_kind_config
  kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG_FILE"

  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v control-plane); do
    kubectl label node "$node" hardware-type=gpu --overwrite
    kubectl taint node "$node" gpu=true:NoSchedule --overwrite
    if [ "$gpu_type" = "rocm" ]; then
      kubectl label node "$node" rocm.amd.com/gpu.present=true --overwrite
      kubectl patch node "$node" --type=json \
        -p='[{"op": "add", "path": "/status/capacity/amd.com~1gpu", "value":"2"}]' --subresource=status
    elif [ "$gpu_type" = "nvidia" ]; then
      kubectl label node "$node" nvidia.com/gpu.present=true --overwrite
      kubectl patch node "$node" --type=json \
        -p='[{"op": "add", "path": "/status/capacity/nvidia.com~1gpu", "value":"2"}]' --subresource=status
    fi
  done
}

function apply_local_registry_configmap() {
  echo "Applying local registry ConfigMap for Kubernetes..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

function build_and_push_images() {
  gpu_type="$1"
  if [ "$gpu_type" = "nvidia" ]; then
    echo " Building NVIDIA device plugin locally..."
    if [ ! -d k8s-device-plugin-nvidia ]; then
      git clone https://github.com/NVIDIA/k8s-device-plugin.git k8s-device-plugin-nvidia
    fi
    cd k8s-device-plugin-nvidia
    cr build \
      --build-arg GOLANG_VERSION=1.21.6 \
      -t localhost:${REGISTRY_PORT}/nvidia-device-plugin:dev \
      -f deployments/container/Dockerfile \
      .
    cr push localhost:${REGISTRY_PORT}/nvidia-device-plugin:dev
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
  cr build -t localhost:${REGISTRY_PORT}/amdgpu-dp:dev -f Dockerfile .
  cr push localhost:${REGISTRY_PORT}/amdgpu-dp:dev
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

  IMAGE_URL="localhost:${REGISTRY_PORT}/amdgpu-dp:dev"
  if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo "Saving image for Podman and loading into Kind..."
    IMAGE_URL="localhost/amdgpu-dp:dev"
    cr tag localhost:${REGISTRY_PORT}/amdgpu-dp:dev localhost/amdgpu-dp:dev
    cr save localhost/amdgpu-dp:dev -o /tmp/image.tar
    kind load image-archive /tmp/image.tar --name "$CLUSTER_NAME"
    rm -f /tmp/image.tar
  fi

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: amdgpu-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: amdgpu-device-plugin
  template:
    metadata:
      labels:
        app: amdgpu-device-plugin
    spec:
      nodeSelector:
        hardware-type: gpu
      tolerations:
        - key: gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: amdgpu-dp-ds
          image: ${IMAGE_URL}
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
EOF

  echo " Giving the DaemonSet a few seconds to initialize..."
  sleep 5

  echo " Waiting for ROCm device plugin pods to become Ready..."
  if ! kubectl wait --for=condition=Ready -n kube-system pod -l app=amdgpu-device-plugin --timeout=60s; then
    echo >&2 " ERROR: ROCm device plugin pods did not become Ready in time. Exiting."
    exit 1
  fi
}

function deploy_nvidia_plugin() {
  echo " Deploying NVIDIA GPU device plugin..."

  IMAGE_URL="localhost:${REGISTRY_PORT}/nvidia-device-plugin:dev"
  if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo "Saving NVIDIA plugin image for Podman and loading into Kind..."
    IMAGE_URL="localhost/nvidia-device-plugin:dev"
    cr tag localhost:${REGISTRY_PORT}/nvidia-device-plugin:dev $IMAGE_URL || true
    cr save $IMAGE_URL -o /tmp/image.tar
    kind load image-archive /tmp/image.tar --name "$CLUSTER_NAME"
    rm -f /tmp/image.tar
  fi

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: nvidia-device-plugin
  template:
    metadata:
      labels:
        app: nvidia-device-plugin
    spec:
      nodeSelector:
        hardware-type: gpu
      tolerations:
        - key: gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: nvidia-device-plugin-ctr
          image: ${IMAGE_URL}
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

  echo " Giving the DaemonSet a few seconds to initialize..."
  sleep 5

  echo " Waiting for NVIDIA device plugin pods to become Ready..."
  if ! kubectl wait --for=condition=Ready -n kube-system pod -l app=nvidia-device-plugin --timeout=60s; then
    echo >&2 " ERROR: NVIDIA device plugin pods did not become Ready in time. Exiting."
    exit 1
  fi
}

function ramalama_deploy_model() {
  MODEL_NAME="$1"
  IMAGE_TAG="$(basename "$MODEL_NAME" | tr '[:upper:]' '[:lower:]' | tr ':' '-' | tr '/' '-')"
  CONTAINER_NAME="$(echo "${IMAGE_TAG}" | tr '.' '-' | tr '[:upper:]' '[:lower:]')"
  IMAGE_NAME="localhost:${REGISTRY_PORT}/${IMAGE_TAG}:dev"

  echo "Removing stale image if it exists..."
  cr rmi -f "$IMAGE_NAME" 2>/dev/null || true

  echo "Converting Hugging Face model '${MODEL_NAME}' to OCI image..."
  if ! ramalama convert "huggingface://${MODEL_NAME}" "oci://${IMAGE_NAME}" 2>&1 | tee convert.log | grep -q "unauthorized"; then
    echo "Model converted successfully: ${IMAGE_NAME}"
  else
    echo "Conversion failed. Aborting."
    exit 1
  fi

  echo "Retagging and pushing image to local registry..."
  IMAGE_ID=$(cr images --format "{{.Repository}} {{.Tag}} {{.ID}}" | grep "<none>" | awk '{print $3}' | head -n1)
  if [ -z "$IMAGE_ID" ]; then
    echo "ERROR: No untagged image found to tag and push. Aborting."
    cr images | grep tinyllama || true
    exit 1
  fi

  cr tag "$IMAGE_ID" "$IMAGE_NAME"

  if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo "Saving model image for Podman and loading into Kind..."
    IMAGE_NAME="localhost/${IMAGE_TAG}:dev"
    cr tag localhost:${REGISTRY_PORT}/${IMAGE_TAG}:dev "$IMAGE_NAME"
    cr save "$IMAGE_NAME" -o /tmp/image.tar
    kind load image-archive /tmp/image.tar --name "$CLUSTER_NAME"
    rm -f /tmp/image.tar
  else
    cr push "$IMAGE_NAME"
    cr pull "$IMAGE_NAME"
    kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"
  fi

  RAMALAMA_VERSION="0.8.1"
  RAMALAMA_IMAGE="quay.io/ramalama/ramalama:${RAMALAMA_VERSION}"
  RUNTIME_IMAGE_LOCAL="localhost:${REGISTRY_PORT}/ramalama:${RAMALAMA_VERSION}"

  cr pull "$RAMALAMA_IMAGE"
  cr tag "$RAMALAMA_IMAGE" "$RUNTIME_IMAGE_LOCAL"

  if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo "Saving RamaLama runtime image for Podman and loading into Kind..."
    LOCAL_IMAGE="localhost/ramalama:${RAMALAMA_VERSION}"
    cr tag "$RAMALAMA_IMAGE" "$LOCAL_IMAGE"
    cr save "$LOCAL_IMAGE" -o /tmp/image.tar
    kind load image-archive /tmp/image.tar --name "$CLUSTER_NAME"
    rm -f /tmp/image.tar
  else
    cr push "$RUNTIME_IMAGE_LOCAL"
    kind load docker-image "$RUNTIME_IMAGE_LOCAL" --name "$CLUSTER_NAME"
  fi

  echo " Generating Kubernetes manifest..."
  ramalama serve \
    --name "${CONTAINER_NAME}" \
    --generate=kube \
    --runtime-args="llama.cpp" \
    "oci://${IMAGE_NAME}"

  YAML_NAME=$(ls *.yaml | grep "${CONTAINER_NAME}" | head -n1)
  echo " Fixing generated YAML: ${YAML_NAME}"

  yq eval '
(.spec.template.spec.containers[0].env) = [
  {"name": "LLAMA_SSE4", "value": "\"1\""},
  {"name": "LLAMA_AVX", "value": "\"0\""},
  {"name": "LLAMA_AVX2", "value": "\"0\""},
  {"name": "LLAMA_FMA", "value": "\"0\""},
  {"name": "LLAMA_F16C", "value": "\"0\""}
]
' -i "$YAML_NAME"

  sed -i 's/apiVersion: v1/apiVersion: apps\/v1/' "$YAML_NAME"
  sed -i '/volumes:/,/type: DirectoryOrCreate/ d' "$YAML_NAME"
  sed -i 's/subPath: \/models/subPath: models/' "$YAML_NAME"
  sed -i "0,/name: .*/s/name: .*/name: ${CONTAINER_NAME}/" "$YAML_NAME"
  sed -i "0,/app: .*/s/app: .*/app: ${CONTAINER_NAME}/" "$YAML_NAME"
  if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    sed -i "s|image: .*ramalama.*|image: ramalama:${RAMALAMA_VERSION}|" "$YAML_NAME"
  else
    sed -i "s|image: .*ramalama.*|image: ${RUNTIME_IMAGE_LOCAL}|" "$YAML_NAME"
  fi


  cat <<EOF >> "$YAML_NAME"
      volumes:
      - name: model
        emptyDir: {}
      - name: dri
        hostPath:
          path: /dev/dri
          type: DirectoryOrCreate
      tolerations:
      - key: "gpu"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
EOF

  if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo "Removing /dev/kfd references for Podman..."
    sed -i '/mountPath: \/dev\/kfd/,+1 d' "$YAML_NAME"
    sed -i '/- name: kfd/,+2 d' "$YAML_NAME"
  fi

  echo " Deploying model to Kubernetes..."
  if kubectl apply -f "$YAML_NAME"; then
    echo " Model '${MODEL_NAME}' is now running in your Kind cluster!"
  else
    echo " Failed to apply manifest. Inspect ${YAML_NAME} for issues."
    return 1
  fi

  echo " Creating Service to expose model..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${CONTAINER_NAME}-svc
spec:
  selector:
    app: ${CONTAINER_NAME}
  ports:
    - name: http
      port: 8080
      targetPort: 8080
EOF

cat <<EOF

You can now test the model via:
    kubectl port-forward svc/${CONTAINER_NAME}-svc 8080:8080

Then:
    curl -X POST http://localhost:8080/completion \
      -H 'Content-Type: application/json' \
      -d '{"prompt": "What is the capital of France?", "n_predict": 32}'

EOF
}


function teardown_ramalama_model() {
  MODEL_NAME="$1"
  IMAGE_TAG="$(basename "$MODEL_NAME" | tr '[:upper:]' '[:lower:]' | tr ':' '-' | tr '/' '-')"
  CONTAINER_NAME="$(echo "${IMAGE_TAG}" | tr '.' '-' | tr '[:upper:]' '[:lower:]')"

  echo " Tearing down deployed model '${MODEL_NAME}'..."

  if kubectl get deployment "${CONTAINER_NAME}" &>/dev/null; then
    kubectl delete deployment "${CONTAINER_NAME}"
  fi

  if kubectl get service "${CONTAINER_NAME}-svc" &>/dev/null; then
    kubectl delete service "${CONTAINER_NAME}-svc"
  fi

  if [ -f "${CONTAINER_NAME}.yaml" ]; then
    rm -f "${CONTAINER_NAME}.yaml"
  fi

  echo " Model '${MODEL_NAME}' has been removed from the cluster."
}

function delete_cluster() {
  echo " Deleting kind cluster..."
  kind delete cluster --name "${CLUSTER_NAME}"
}

function delete_registry() {
  echo "Deleting local Docker registry '${REGISTRY_NAME}'..."

  if docker ps -q -f "name=^/${REGISTRY_NAME}$" &>/dev/null; then
    echo "  Stopping registry container..."
    docker stop "${REGISTRY_NAME}" >/dev/null
  fi

  if docker ps -aq -f "name=^/${REGISTRY_NAME}$" &>/dev/null; then
    echo "  Removing registry container..."
    docker rm "${REGISTRY_NAME}" >/dev/null
  fi
}

function usage() {
  echo "Usage: $0 {create [rocm|nvidia]|delete}"
  exit 1
}

case "$1" in
  create)
  gpu_type=${2:-rocm}
  ramalama_model=""
  for arg in "$@"; do
    case "$arg" in
      --ramalama-model=*)
        ramalama_model="${arg#*=}"
        ;;
    esac
  done

  start_local_registry
  create_kind_cluster "$gpu_type"
  apply_local_registry_configmap
  build_and_push_images "$gpu_type"
  deploy_device_plugin "$gpu_type"

  if [[ -n "$ramalama_model" ]]; then
    echo "Deploying model with RamaLama: $ramalama_model"
    ramalama_deploy_model "$ramalama_model"
  fi

  echo " Simulated GPU Kind cluster is ready for '${gpu_type}'!"
  ;;
  delete)
    delete_cluster
    if [ "$CONTAINER_RUNTIME" = "docker" ]; then
      delete_registry
    fi
    ;;
  ramalama-redeploy-model)
    if [ -z "$2" ]; then
      echo " Please provide a model name to redeploy."
      exit 1
    fi
    teardown_ramalama_model "$2"
    ramalama_deploy_model "$2"
    ;;
  *)
    usage
    ;;
esac
