# EKS Karpenter Terraform

This repository contains Terraform code to deploy an Amazon EKS cluster with Karpenter for auto-scaling. The configuration supports both x86 (AMD64) and ARM64 (Graviton) instances, as well as GPU instances with GPU time-slicing enabled.

## Features

- EKS cluster with latest version
- Karpenter auto-scaling
- Support for both x86 and ARM64 (Graviton) instances
- GPU support with time-slicing enabled
- Spot and On-Demand instance support
- Cost optimization through instance diversity

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0.0
- kubectl
- An existing VPC with appropriate subnets

## Getting Started

1. Configure your AWS credentials:
   ```bash
   export AWS_PROFILE=your-profile
   ```

2. Initialize Terraform:
   ```bash
   terraform init
   ```

3. Apply the configuration:
   ```bash
   terraform apply
   ```

This will automatically:
- Create the EKS cluster
- Configure Karpenter for node provisioning
- Set up GPU support including:
  - NVIDIA device plugin
  - GPU time-slicing
  - NVIDIA runtime configuration
  - MPS DaemonSet
  - All necessary ConfigMaps and RuntimeClasses

No manual steps are required. The entire GPU infrastructure is automatically configured through Terraform.

## Running Workloads

### Running on x86 (AMD64)
```yaml
apiVersion: apps/v1
kind: Deployment
name: app-x86
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
      containers:
      - name: app
        image: your-image:tag
```

### Running on ARM64 (Graviton)
```yaml
apiVersion: apps/v1
kind: Deployment
name: app-arm
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
      - name: app
        image: your-image:tag
```

### Running GPU Workloads with Time-Slicing
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  containers:
  - name: cuda-container
    image: nvidia/cuda:11.6.2-base-ubuntu20.04
    resources:
      limits:
        nvidia.com/gpu: "0.25" # Request 1/4 of a GPU
    command: ["nvidia-smi"]
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
```

## GPU Support and Time-Slicing

This EKS cluster is configured to support GPU workloads with NVIDIA GPU time-slicing enabled. This allows multiple pods to share a single GPU, improving resource utilization and cost efficiency. All components are automatically deployed and configured by Terraform.

### Components (Automatically Deployed)

1. **Karpenter GPU Node Pool**
   - Configured to provision GPU instances (G5 and P4d families)
   - Uses spot instances for cost optimization
   - Automatically scales based on GPU demand

2. **NVIDIA Device Plugin**
   - Automatically deployed via Helm chart
   - Enables GPU support in Kubernetes
   - Pre-configured with GPU time-slicing
   - Includes RuntimeClass configuration

3. **NVIDIA Multi-Process Service (MPS)**
   - Automatically deployed as a DaemonSet
   - Enables efficient GPU sharing between pods
   - Pre-configured to start on GPU nodes

### Configuration Details (All Automated)

1. **GPU Node Pool Settings**
   - Instance types: G5 and P4d families
   - Uses spot instances for cost optimization
   - Pre-configured with appropriate taints and labels
   - Automatic scaling based on GPU demand

2. **GPU Time-Slicing**
   - Automatically configured via ConfigMap
   - Allows fractional GPU allocation (e.g., 0.5 or 0.25 GPU)
   - Improves GPU utilization for smaller workloads

3. **NVIDIA Runtime**
   - RuntimeClass automatically created and configured
   - Pre-configured on all GPU nodes
   - No manual setup required

### Usage

After running `terraform apply`, you can immediately start deploying GPU workloads:

1. **Requesting GPU Resources**
   ```yaml
   resources:
     limits:
       nvidia.com/gpu: "0.5"  # Request half a GPU
   ```

2. **Using NVIDIA Runtime** (Already configured)
   ```yaml
   spec:
     runtimeClassName: nvidia  # RuntimeClass is automatically created
   ```

3. **Example Workloads**
   - Ready-to-use examples in `examples/gpu-workloads/`:
     - Training job example
     - Inference deployment example
     - GPU sharing demonstration

### Automatic Provisioning

Everything is automated through Terraform. When you deploy a GPU workload:
1. Karpenter automatically detects the GPU requirement
2. Provisions an appropriate GPU node
3. NVIDIA device plugin automatically deploys
4. GPU time-slicing is automatically configured
5. Workload is scheduled with GPU access

No manual intervention is required at any step.

## Node Pools

The configuration includes two node pools:

1. **General Purpose (general)**
   - Supports both x86 and ARM64 architectures
   - Instance types: t3.small, t3.medium, c6g.medium, c6g.large, m6g.medium, m6g.large
   - Uses both Spot and On-Demand instances

2. **GPU (gpu)**
   - Supports NVIDIA GPUs with time-slicing
   - Instance types: g5.xlarge, g5.2xlarge, p4d.24xlarge
   - GPU time-slicing enabled (4 virtual GPUs per physical GPU)

## Monitoring

To check the status of your nodes:
```bash
kubectl get nodes -L kubernetes.io/arch
```

To check GPU allocation:
```bash
kubectl describe node <node-name> | grep nvidia.com/gpu
```

## Cost Optimization

This setup optimizes costs through:
- Use of Spot instances where possible
- ARM64 (Graviton) instances for better price/performance
- GPU time-slicing for better GPU utilization
- Karpenter's efficient node provisioning and termination

## Troubleshooting

If pods are not scheduling as expected, check:
1. Node pool requirements match your pod specifications
2. Sufficient capacity in your AWS account
3. Karpenter logs: `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter`
