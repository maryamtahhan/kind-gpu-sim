
# kind-gpu-sim

Simulate **NVIDIA** or **AMD (ROCm)** GPUs in a
[Kubernetes in Docker (kind)](https://kind.sigs.k8s.io/)
cluster, without requiring actual GPU hardware.

This is perfect for:

- Testing GPU scheduling
- Validating device plugin behavior
- Learning how GPU workloads interact with Kubernetes
- Building GPU-related Kubernetes infrastructure
  (where no real workloads are required).

## ⚠️ Important: No Real GPU Support

> This project **simulates** the presence of GPU resources in a Kind
> cluster. It **does not provide access to actual GPU hardware**,
> and **real GPU workloads (like CUDA or ROCm kernels)** will **not run**.

## Prerequisites

Make sure the following tools are installed on your system before running
the GPU simulator script:

<!-- markdownlint-disable  MD013 -->
<!-- Teporarily disable MD013 - Line length to keep the table formatting  -->
| Tool         | Purpose                                                              |
|--------------|----------------------------------------------------------------------|
| **docker**   | Required by `kind`, runs the local registry and all cluster nodes    |
| **kind**     | Creates the local Kubernetes cluster inside Docker                   |
| **kubectl**  | CLI to interact with the Kubernetes cluster                          |
| **git**      | Clones the GPU device plugin repositories (NVIDIA / ROCm)            |
| **sed**      | Used to patch Dockerfiles for public registry compatibility          |
<!-- markdownlint-enable  MD013 -->

## Features

- Kind cluster with 1 control-plane + 2 workers
- Simulated `amd.com/gpu` or `nvidia.com/gpu` resources
- Automatically taints and labels GPU nodes
- Uses a local container registry
- Builds and deploys the AMD ROCm device plugin (locally)
- Builds and deploys NVIDIA plugin (locally)
- Includes GPU test pod manifests

## Quick Start

### 1. Clone the repo and make the script executable

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

Create a pod that requests GPU resources:

#### For NVIDIA

```bash
kubectl create -f pods/nvidia-gpu-test-pod.yaml
```

Check pod logs

```bash
kubectl logs nvidia-gpu-test
Hello from fake NVIDIA GPU node
```

#### For AMD

```bash
kubectl create -f pods/rocm-gpu-test-pod.yaml
```

Check pod logs

```bash
kubectl logs gpu-rocm-test
Hello from fake ROCm GPU node
```

### 4. Tear down the cluster

```bash
./kind-gpu-sim.sh delete
```

## File Structure

```bash
.
├── kind-gpu-config.yaml          # Kind cluster config: 1 control-plane, 2 workers
├── kind-gpu-sim.sh               # Main script to create/delete simulated GPU clusters (ROCm or NVIDIA)
├── pods
│   ├── nvidia-gpu-test-pod.yaml  # Pod spec to test NVIDIA GPU simulation (uses nvidia.com/gpu)
│   ├── rocm-gpu-test-pod.yaml    # Pod spec to test AMD ROCm GPU simulation (uses amd.com/gpu)
│   └── triton-pod.yaml           # Pod that installs and runs Triton-lang, useful for simulating kernel compilation
└── Readme.md                     # Project overview and usage instructions
```

## How It Works

| Component            | Description                                           |
|----------------------|-------------------------------------------------------|
| `kubectl patch`      | Fakes `amd.com/gpu` or `nvidia.com/gpu` on nodes      |
| `taint + toleration` | Ensures only GPU workloads land on simulated nodes    |
| `DaemonSet`          | Deploys either AMD or NVIDIA device plugin DaemonSets |
| `localhost:5000`     | Local registry, connected to Kind                     |

## Tested With

- kind v0.23.0

## Why Simulate?

This project helps:

- Devs test GPU workloads without expensive hardware
- CI environments validate GPU scheduling logic
- Anyone learn Kubernetes GPU primitives
