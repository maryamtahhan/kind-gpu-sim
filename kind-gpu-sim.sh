
#!/bin/bash
set -e

REGISTRY_PORT=5000
ECR_REGISTRY_IMAGE=public.ecr.aws/docker/library/registry:2

for arg in "$@"; do
  case "$arg" in
    --registry-port=*)
      REGISTRY_PORT="${arg#*=}"
      ;;
  esac
done

CLUSTER_NAME=kind-gpu-sim
CONFIG_FILE=kind-gpu-config.yaml
REGISTRY_NAME="kind-registry"

function start_local_registry() {
  echo "Starting local Docker registry on port ${REGISTRY_PORT}..."

  running=$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo "false")
  if [ "$running" != "true" ]; then
    docker run -d --restart=always -p "${REGISTRY_PORT}:5000" \
      --name "${REGISTRY_NAME}" "${ECR_REGISTRY_IMAGE}"
  else
    echo "Registry '${REGISTRY_NAME}' already running."
  fi

  echo "Ensuring the registry is connected to the Kind network..."
  docker network connect kind "${REGISTRY_NAME}" 2>/dev/null || true
}

function generate_kind_config() {
  if [ -f "${CONFIG_FILE}" ]; then
    echo "Config file ${CONFIG_FILE} already exists. Deleting it..."
    rm -f "${CONFIG_FILE}"
  fi

  echo "Generating Kind cluster config with registry mirror localhost:${REGISTRY_PORT}..."
  cat > "${CONFIG_FILE}" <<EOF
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

function create_kind_cluster() {
  gpu_type="$1"
  generate_kind_config
  echo "Creating kind cluster with 1 control-plane + 2 workers..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG_FILE}"

  echo "Connecting registry to kind network..."
  docker network connect "kind" "${REGISTRY_NAME}" || true

  echo "Detecting worker nodes dynamically..."
  worker_nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v control-plane)

  echo "Patching worker nodes with fake '${gpu_type}' GPUs..."
  for node in $worker_nodes; do
    echo "Working on $node"
    kubectl label node "${node}" hardware-type=gpu --overwrite
    kubectl label node "${node}" node-role.kubernetes.io/worker="" --overwrite
    kubectl taint node "${node}" gpu=true:NoSchedule --overwrite

    if [ "$gpu_type" = "rocm" ]; then
      kubectl label node "${node}" rocm.amd.com/gpu.present=true --overwrite
      kubectl patch node "${node}" --type=json \
        -p='[{"op": "add", "path": "/status/capacity/amd.com~1gpu", "value":"2"}]' \
        --subresource=status
    elif [ "$gpu_type" = "nvidia" ]; then
      kubectl label node "${node}" nvidia.com/gpu.present=true --overwrite
      kubectl patch node "${node}" --type=json \
        -p='[{"op": "add", "path": "/status/capacity/nvidia.com~1gpu", "value":"2"}]' \
        --subresource=status
    fi
  done

  echo "Configuring containerd on nodes to recognize local registry mirror..."

  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
    cat <<EOF | docker exec -i "$node" tee "/etc/containerd/certs.d/localhost:${REGISTRY_PORT}/hosts.toml" > /dev/null
[host."http://${REGISTRY_NAME}:5000"]
  capabilities = ["pull", "resolve"]
EOF

    echo "Reloading containerd on $node..."
    docker exec "$node" kill -SIGHUP $(pidof containerd) || echo "Warning: could not reload containerd on $node"
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
          image: localhost:${REGISTRY_PORT}/amdgpu-dp:dev
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

  echo " Removing stale image if it exists..."
  docker rmi -f "$IMAGE_NAME" 2>/dev/null || true

  echo " Converting Hugging Face model '${MODEL_NAME}' to OCI image..."
  if ! ramalama convert "huggingface://${MODEL_NAME}" "oci://${IMAGE_NAME}" 2>&1 | tee convert.log | grep -q "unauthorized"; then
    echo " Model converted successfully: ${IMAGE_NAME}"
  else
    echo " Conversion failed. Aborting."
    exit 1
  fi

  echo " Retagging and pushing image to local registry..."
  IMAGE_ID=$(docker images --format "{{.Repository}} {{.Tag}} {{.ID}}" | grep "<none>" | awk '{print $3}' | head -n1)
  if [ -z "$IMAGE_ID" ]; then
    echo " ERROR: No untagged image found to tag and push. Aborting."
    docker images | grep tinyllama || true
    exit 1
  fi

  docker tag "$IMAGE_ID" "$IMAGE_NAME"
  docker push "$IMAGE_NAME"

  echo " Pulling image back into Docker (for verification)..."
  docker pull "$IMAGE_NAME"

  echo " Loading image into Kind cluster nodes..."
  kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"

  echo " Ensuring RamaLama runtime image is local..."
  RUNTIME_IMAGE_REMOTE="quay.io/ramalama/ramalama:0.7"
  RUNTIME_IMAGE_LOCAL="localhost:${REGISTRY_PORT}/ramalama:0.7"

  docker pull "$RUNTIME_IMAGE_REMOTE"
  docker tag "$RUNTIME_IMAGE_REMOTE" "$RUNTIME_IMAGE_LOCAL"
  docker push "$RUNTIME_IMAGE_LOCAL"
  kind load docker-image "$RUNTIME_IMAGE_LOCAL" --name "$CLUSTER_NAME"

  echo " Generating Kubernetes manifest..."
  ramalama serve \
    --name "${CONTAINER_NAME}" \
    --generate=kube \
    "oci://${IMAGE_NAME}"

  YAML_NAME=$(ls *.yaml | grep "${CONTAINER_NAME}" | head -n1)
  echo " Fixing generated YAML: ${YAML_NAME}"

  sed -i 's/apiVersion: v1/apiVersion: apps\/v1/' "$YAML_NAME"
  sed -i '/volumes:/,/type: DirectoryOrCreate/ d' "$YAML_NAME"
  sed -i 's/subPath: \/models/subPath: models/' "$YAML_NAME"
  sed -i "0,/name: .*/s/name: .*/name: ${CONTAINER_NAME}/" "$YAML_NAME"
  sed -i "0,/app: .*/s/app: .*/app: ${CONTAINER_NAME}/" "$YAML_NAME"
  sed -i "s|quay.io/ramalama/ramalama:0.7|${RUNTIME_IMAGE_LOCAL}|" "$YAML_NAME"

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

  echo ""
  echo " You can now test the model via:"
  echo "    kubectl port-forward svc/${CONTAINER_NAME}-svc 8080:8080"
  echo ""
  echo " Then:"
  echo "    curl -X POST http://localhost:8080/completion \\"
  echo "      -H 'Content-Type: application/json' \\"
  echo "      -d '{\"prompt\": \"What is the capital of France?\", \"n_predict\": 32}'"
  echo ""
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
    delete_registry
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
