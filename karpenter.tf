# Install Karpenter Helm Chart
resource "helm_release" "karpenter" {
  depends_on = [module.eks]
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "v0.33.0"

  set {
    name  = "settings.aws.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.aws.clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter_controller_role.iam_role_arn
  }

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }
}

# Create Karpenter Node Class
resource "kubectl_manifest" "karpenter_node_class" {
  depends_on = [helm_release.karpenter]
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2
      role: ${aws_iam_role.karpenter_node.name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.name}
      tags:
        karpenter.sh/discovery: ${local.name}
        Name: ${local.name}-karpenter-node
        Environment: ${local.tags["Environment"]}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 50Gi
            volumeType: gp3
            encrypted: true
  YAML
}

# Create Karpenter Node Pool for general purpose instances
resource "kubectl_manifest" "karpenter_node_pool_general" {
  depends_on = [kubectl_manifest.karpenter_node_class]
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: general
    spec:
      template:
        spec:
          nodeClassRef:
            name: default
          requirements:
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["t", "c", "m"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["2"]
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64", "arm64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - t3.small
                - t3.medium
                - c6g.medium
                - c6g.large
                - m6g.medium
                - m6g.large
      limits:
        cpu: 100
        memory: 400Gi
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 30s
  YAML
}

# Create Karpenter Node Pool for GPU instances with GPU slicing
resource "kubectl_manifest" "karpenter_node_pool_gpu" {
  depends_on = [kubectl_manifest.karpenter_node_class]
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: gpu
    spec:
      template:
        spec:
          nodeClassRef:
            name: default
          requirements:
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["g", "p"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["4"]
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                # G5 instances - Latest NVIDIA A10G GPUs
                - g5.xlarge    # 1 GPU, good for inference
                - g5.2xlarge   # 1 GPU, good for training
                - g5.4xlarge   # 1 GPU, more CPU/RAM
                - g5.8xlarge   # 1 GPU, maximum CPU/RAM
                # P4 instances - NVIDIA A100 GPUs
                - p4d.24xlarge # 8 GPUs, for large training jobs
          kubelet:
            systemReserved:
              cpu: "100m"
              memory: "100Mi"
              ephemeral-storage: "1Gi"
            kubeReserved:
              cpu: "200m"
              memory: "200Mi"
              ephemeral-storage: "1Gi"
            evictionHard:
              memory.available: "5%"
              nodefs.available: "10%"
              nodefs.inodesFree: "5%"
          labels:
            gpu.nvidia.com/class: "ampere"
            gpu.nvidia.com/type: "a10g"
          taints:
            - key: nvidia.com/gpu
              value: "true"
              effect: NoSchedule
      limits:
        cpu: 1000
        memory: 1000Gi
        nvidia.com/gpu: 100
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 30s
  YAML
}

# Create GPU slicing configuration
resource "kubectl_manifest" "gpu_slicing_config" {
  depends_on = [helm_release.karpenter]
  yaml_body = <<-YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
  namespace: kube-system
data:
  config.yaml: |
    version: v1
    flags:
      migStrategy: none
      failOnInitError: true
      nvidiaDriverRoot: "/"
      plugin:
        passDeviceSpecs: false
        deviceListStrategy: envvar
        deviceIDStrategy: uuid
YAML
}

# Create NVIDIA RuntimeClass
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

# Deploy NVIDIA Device Plugin with GPU Time-Slicing
resource "helm_release" "nvidia_device_plugin" {
  depends_on = [
    kubectl_manifest.gpu_slicing_config,
    kubectl_manifest.nvidia_runtime_class,
    helm_release.karpenter
  ]
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = "kube-system"
  version    = "0.17.0"

  values = [<<-EOT
    config:
      map:
        default: |-
          version: v1
          flags:
            migStrategy: none
            failOnInitError: true
    runtimeClassName: nvidia
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
      limits:
        cpu: 500m
        memory: 500Mi
  EOT
  ]
}

# Deploy NVIDIA MPS DaemonSet
resource "kubectl_manifest" "nvidia_mps_daemonset" {
  depends_on = [
    helm_release.nvidia_device_plugin,
    kubectl_manifest.nvidia_runtime_class
  ]
  yaml_body = <<-YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-mps-daemon
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: nvidia-mps-daemon
  template:
    metadata:
      labels:
        app: nvidia-mps-daemon
    spec:
      runtimeClassName: nvidia
      containers:
      - name: nvidia-mps-daemon
        image: nvidia/cuda:11.8.0-base-ubuntu22.04
        command: ["nvidia-cuda-mps-control", "-d"]
        securityContext:
          privileged: true
        resources:
          limits:
            nvidia.com/gpu: "1"
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
YAML
}
