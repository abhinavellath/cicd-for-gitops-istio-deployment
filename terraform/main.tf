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
  config_path    = pathexpand("~/.kube/config")
  config_context = "minikube"
}

provider "helm" {
  kubernetes {
    config_path    = pathexpand("~/.kube/config")
    config_context = "minikube"
  }
}

# Provision a Minikube Cluster (Windows PowerShell)
resource "null_resource" "minikube_cluster" {
  provisioner "local-exec" {
    command     = "minikube start -p my-gitops-cluster"
    interpreter = ["PowerShell", "-Command"]
  }
  provisioner "local-exec" {
    when        = destroy
    command     = "minikube delete -p my-gitops-cluster"
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

# Install ArgoCD CRDs before Helm release
resource "null_resource" "install_argocd_crds" {
  depends_on = [null_resource.minikube_cluster]

  provisioner "local-exec" {
    command = "kubectl apply -k https://github.com/argoproj/argo-cd/manifests/crds?ref=v2.11.0"
    interpreter = ["PowerShell", "-Command"]
  }
}

# ArgoCD
resource "helm_release" "argocd" {
  depends_on       = [null_resource.install_argocd_crds, helm_release.istiod]
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  wait    = true
  timeout = 600
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
    helm_release.argocd
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
