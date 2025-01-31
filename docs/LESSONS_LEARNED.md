# EKS GPU Optimization: Lessons Learned

This document captures the key challenges encountered and solutions implemented while setting up GPU support with time-slicing on EKS using Karpenter.

## Challenge 1: NVIDIA Device Plugin Deployment Failure

### Issue
The NVIDIA device plugin pods were failing to start with errors related to the RuntimeClass not being found.

### Root Cause
The Helm chart for the NVIDIA device plugin was configured to use the `nvidia` RuntimeClass, but this class wasn't created before the plugin deployment.

### Solution
1. Created a proper dependency chain in Terraform:
   ```hcl
   resource "helm_release" "nvidia_device_plugin" {
     depends_on = [
       kubectl_manifest.gpu_slicing_config,
       kubectl_manifest.nvidia_runtime_class,
       helm_release.karpenter
     ]
     # ... rest of configuration
   }
   ```
2. Ensured the RuntimeClass is created before the device plugin:
   ```hcl
   resource "kubectl_manifest" "nvidia_runtime_class" {
     depends_on = [helm_release.karpenter]
     yaml_body = <<-YAML
     apiVersion: node.k8s.io/v1
     kind: RuntimeClass
     metadata:
       name: nvidia
     handler: nvidia
     YAML
   }
   ```

## Challenge 2: GPU Time-Slicing Configuration

### Issue
Initial GPU time-slicing configuration was too complex and caused issues with pod scheduling.

### Root Cause
The original configuration used advanced NVIDIA MPS settings that weren't fully compatible with the current version of the device plugin.

### Solution
1. Simplified the configuration to use basic time-slicing:
   ```yaml
   version: v1
   flags:
     migStrategy: none
     failOnInitError: true
   ```
2. Moved advanced settings to the MPS DaemonSet configuration
3. Used the latest version (0.17.0) of the NVIDIA device plugin

## Challenge 3: Resource Allocation

### Issue
Pods were not properly sharing GPU resources, leading to resource conflicts.

### Root Cause
Missing proper resource limits and MPS configuration in the DaemonSet.

### Solution
1. Implemented proper resource requests and limits:
   ```yaml
   resources:
     limits:
       nvidia.com/gpu: "1"
   ```
2. Added proper node selectors and tolerations:
   ```yaml
   nodeSelector:
     nvidia.com/gpu.present: "true"
   tolerations:
   - key: nvidia.com/gpu
     operator: Exists
     effect: NoSchedule
   ```

## Challenge 4: Helm Release Management

### Issue
Helm releases were getting stuck in a failed state when configurations needed updates.

### Root Cause
Terraform wasn't properly handling Helm release updates and dependencies.

### Solution
1. Added proper cleanup in Terraform:
   ```hcl
   lifecycle {
     create_before_destroy = true
   }
   ```
2. Implemented proper version pinning for Helm charts
3. Added explicit dependencies between resources

## Challenge 5: Node Provisioning Delays

### Issue
GPU nodes were taking too long to be provisioned when needed.

### Root Cause
Karpenter provisioner configuration wasn't optimized for GPU workloads.

### Solution
1. Updated Karpenter provisioner to prefer specific instance types:
   ```yaml
   requirements:
     - key: node.kubernetes.io/instance-type
       operator: In
       values: ["g5.xlarge", "g5.2xlarge", "p4d.24xlarge"]
   ```
2. Added proper taints and tolerations to ensure GPU workloads land on GPU nodes
3. Configured proper scaling settings to reduce provisioning time

## Best Practices Learned

1. **Resource Dependencies**
   - Always explicitly define resource dependencies in Terraform
   - Use `depends_on` for resources that need specific ordering
   - Consider using data sources for dynamic configurations

2. **Configuration Management**
   - Keep configurations simple and standardized
   - Use version pinning for all components
   - Document all configuration options and their impacts

3. **Testing and Validation**
   - Create test workloads to validate GPU functionality
   - Monitor resource utilization during testing
   - Validate time-slicing functionality with multiple pods

4. **Monitoring and Debugging**
   - Set up proper logging for GPU components
   - Monitor GPU utilization and allocation
   - Keep track of pod scheduling events

5. **Cost Optimization**
   - Use spot instances where possible
   - Implement proper node draining
   - Monitor GPU utilization to adjust time-slicing settings

## Future Improvements

1. **Automated Testing**
   - Implement automated tests for GPU functionality
   - Add validation jobs for time-slicing
   - Create performance benchmarks

2. **Monitoring**
   - Add GPU-specific metrics collection
   - Create dashboards for GPU utilization
   - Set up alerts for GPU-related issues

3. **Cost Optimization**
   - Implement dynamic time-slicing based on workload
   - Add support for different GPU instance types
   - Optimize node provisioning strategies
