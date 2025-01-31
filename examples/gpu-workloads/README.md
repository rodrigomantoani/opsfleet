# GPU Time-Slicing Examples for AI Workloads

This directory contains example configurations for running AI workloads with GPU time-slicing on EKS with Karpenter.

## GPU Time-Slicing Configuration

Our setup uses NVIDIA Multi-Process Service (MPS) for optimal GPU sharing, configured with:
- 4 virtual GPUs per physical GPU
- Memory limits per slice
- Different time-slice durations for training and inference

### Time-Slicing Policies

1. **Training Workloads (Guaranteed)**
   - Longer time slices (1000ms-2000ms)
   - Higher memory allocation
   - Better for batch processing and training jobs

2. **Inference Workloads (Best-Effort)**
   - Shorter time slices (100ms-500ms)
   - Lower memory allocation
   - Optimized for real-time inference

## Example Workloads

### 1. Training Job
```bash
kubectl apply -f training-job.yaml
```
- Uses 0.5 GPU (half of a physical GPU)
- Guaranteed time-slicing policy
- Suitable for model training tasks

### 2. Inference Deployment
```bash
kubectl apply -f inference-deployment.yaml
```
- Uses 0.25 GPU (quarter of a physical GPU)
- Best-effort time-slicing policy
- Optimized for serving models

## Monitoring GPU Usage

Check GPU allocation:
```bash
kubectl exec -it -n kube-system $(kubectl get pods -n kube-system -l name=nvidia-mps-daemon -o name) -- nvidia-smi
```

Monitor GPU metrics:
```bash
kubectl top pods --containers
```

## Cost Optimization Tips

1. **Instance Selection**
   - Use G5 instances for general ML workloads
   - Use P4d instances for large training jobs
   - Enable Spot instances for non-critical workloads

2. **GPU Sharing Best Practices**
   - Group similar workloads on the same GPU
   - Use appropriate time-slice durations
   - Monitor GPU memory usage

3. **Workload Scheduling**
   - Use node affinity for workload placement
   - Implement pod disruption budgets
   - Set appropriate resource requests/limits

## Troubleshooting

Common issues and solutions:

1. **GPU Not Detected**
   ```bash
   kubectl logs -n kube-system -l name=nvidia-device-plugin-daemonset
   ```

2. **MPS Issues**
   ```bash
   kubectl logs -n kube-system -l name=nvidia-mps-daemon
   ```

3. **Resource Constraints**
   ```bash
   kubectl describe pod <pod-name>
   ```
