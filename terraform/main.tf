terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.22"
    }
  }
}

provider "kubernetes" {
  config_path = pathexpand("~/.kube/config")
}

# Provision a Minikube Cluster (Windows PowerShell)
resource "null_resource" "minikube_cluster" {
  provisioner "local-exec" {
    command     = "minikube create cluster --name my-gitops-cluster"
    interpreter = ["PowerShell", "-Command"]
  }
  provisioner "local-exec" {
    when        = destroy
    command     = "minikube delete cluster --name my-gitops-cluster"
    interpreter = ["PowerShell", "-Command"]
  }
}

# Istio Base & Istiod
resource "helm_release" "istio_base" {
  depends_on       = [null_resource.minikube_cluster]
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  namespace        = "istio-system"
  create_namespace = true
}

resource "helm_release" "istiod" {
  depends_on       = [helm_release.istio_base]
  name             = "istiod"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "istiod"
  namespace        = "istio-system"
  values = [
    <<-EOT
    global:
      hub: gcr.io/istio-release
      tag: 1.20.0
    meshConfig:
      accessLogFile: "/dev/stdout"
    EOT
  ]
}

# ArgoCD
resource "helm_release" "argocd" {
  depends_on       = [null_resource.minikube_cluster, helm_release.istiod]
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  # ✅ Ensure Terraform waits for CRDs & resources
  wait    = true
  timeout = 600
}

# Wait for ArgoCD CRDs to be registered before creating Applications
resource "null_resource" "wait_for_argocd_crds" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = "kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s"
    interpreter = ["PowerShell", "-Command"]
  }
}

# Prometheus and Grafana
resource "helm_release" "prometheus" {
  depends_on       = [null_resource.minikube_cluster, helm_release.istiod]
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
}

# ArgoCD Application
resource "kubernetes_manifest" "my_app_argocd" {
  depends_on = [
    helm_release.argocd,
    null_resource.wait_for_argocd_crds
  ]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "my-gitops-app"
      namespace = "argocd"
    }
    spec = {
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "default"
      }
      project = "default"
      source = {
        repoURL        = "https://github.com/abhinavellath/cicd-for-gitops-istio-deployment.git"
        targetRevision = "main"
        path           = "manifests/my-app"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  }
}
