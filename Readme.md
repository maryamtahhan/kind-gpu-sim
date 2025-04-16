
# kind-gpu-sim

Simulate **NVIDIA** or **AMD (ROCm)** GPUs in a local [Kubernetes in Docker (kind)](https://kind.sigs.k8s.io/) cluster, without requiring actual GPU hardware.

This is perfect for:
- Testing GPU scheduling
- Validating device plugin behavior
- Learning how GPU workloads are handled by Kubernetes

## Features

- Kind cluster with 1 control-plane + 2 workers
- Simulated `amd.com/gpu` or `nvidia.com/gpu` resources
- Automatically taints and labels GPU nodes
- Uses a local container registry
- Avoids Docker Hub rate limits using Amazon ECR Public
- Builds and deploys the AMD ROCm device plugin (locally)
- Deploys NVIDIA plugin (pulled from ECR Public)
- Includes GPU test pod manifests

## Quick Start

### 1. Clone the repo and make the script executable:

```bash
chmod +x kind-gpu-sim.sh
```

### 2. Start the simulated GPU cluster

Choose your simulation type:

```bash
# Simulate AMD GPUs
./kind-gpu-sim.sh create rocm

# Simulate NVIDIA GPUs
./kind-gpu-sim.sh create nvidia
```

### 3. (Optional) Test a simulated GPU pod

Apply a pod that requests GPU resources:

#### For NVIDIA:

```bash
kubectl apply -f nvidia-gpu-test-pod.yaml
```

#### For AMD:

Update the manifest to use `amd.com/gpu` and apply similarly.

### 4. Tear down the cluster

```bash
./kind-gpu-sim.sh delete
```

##  File Structure

```bash
.
├── ./kind-gpu-config.yaml         # Kind cluster config: 1 control-plane, 2 workers
├── ./kind-gpu-sim.sh              # Main script to create/delete simulated GPU clusters (ROCm or NVIDIA)
├── ./nvidia-gpu-test-pod.yaml     # Pod spec to test NVIDIA GPU simulation (uses nvidia.com/gpu)
├── ./Readme.md                    # Project overview and usage instructions
├── ./rocm-gpu-test-pod.yaml       # Pod spec to test AMD ROCm GPU simulation (uses amd.com/gpu)
└── ./triton-pod.yaml              # Pod that installs and runs Triton-lang, useful for simulating kernel compilation
```

##  How It Works

| Component            | Description                                           |
|----------------------|-------------------------------------------------------|
| `kubectl patch`      | Fakes `amd.com/gpu` or `nvidia.com/gpu` on nodes      |
| `taint + toleration` | Ensures only GPU workloads land on simulated nodes    |
| `DaemonSet`          | Deploys either AMD or NVIDIA device plugin DaemonSets |
| `localhost:5000`     | Local registry, connected to Kind                     |

## Tested With

- kind v0.22+
- Kubernetes v1.30+
- Docker with Amazon ECR Public access

## Why Simulate?

This project helps:
- Devs test GPU workloads without expensive hardware
- CI environments validate GPU scheduling logic
- Anyone learn Kubernetes GPU primitives

