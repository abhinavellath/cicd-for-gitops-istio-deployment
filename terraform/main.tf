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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
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

# ----------------------------------------
# Generate unique suffix for namespaces
# ----------------------------------------
resource "random_id" "suffix" {
  byte_length = 2
}

locals {
  istio_namespace = "istio-system-${random_id.suffix.hex}"
}

# ----------------------------------------
# Provision Minikube Cluster
# ----------------------------------------
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

# ----------------------------------------
# Wait for Kubernetes API
# ----------------------------------------
resource "null_resource" "wait_for_k8s" {
  depends_on = [null_resource.minikube_cluster]

  provisioner "local-exec" {
    command = <<EOT
      $maxRetries=30
      $count=0
      while ($count -lt $maxRetries) {
        try {
          kubectl get nodes
          Write-Output " Kubernetes API is ready."
          exit 0
        } catch {
          Write-Output " Waiting for Kubernetes API... retry $count"
          Start-Sleep -Seconds 10
          $count++
        }
      }
      Write-Error "Kubernetes API not ready after waiting."
      exit 1
    EOT
    interpreter = ["PowerShell", "-Command"]
  }
}

# ----------------------------------------
# Add and update Helm repos
# ----------------------------------------
resource "null_resource" "helm_repos" {
  depends_on = [null_resource.wait_for_k8s]

  provisioner "local-exec" {
    command = <<EOT
      helm repo add istio https://istio-release.storage.googleapis.com/charts
      helm repo add argocd https://argoproj.github.io/argo-helm
      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
      helm repo update
    EOT
    interpreter = ["PowerShell", "-Command"]
  }
}

# ----------------------------------------
# Cleanup conflicting Istio ServiceAccount
# ----------------------------------------
resource "null_resource" "cleanup_istio_sa" {
  depends_on = [null_resource.helm_repos]

  provisioner "local-exec" {
    command = <<EOT
      kubectl delete serviceaccount istio-reader-service-account -n ${local.istio_namespace} --ignore-not-found
    EOT
    interpreter = ["PowerShell", "-Command"]
  }
}

# ----------------------------------------
# Istio Base
# ----------------------------------------
resource "helm_release" "istio_base" {
  depends_on       = [null_resource.cleanup_istio_sa]
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  namespace        = local.istio_namespace
  create_namespace = true
  version          = "1.23.0"
}

# ----------------------------------------
# Istiod
# ----------------------------------------
resource "helm_release" "istiod" {
  depends_on       = [helm_release.istio_base]
  name             = "istiod"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "istiod"
  namespace        = local.istio_namespace
  version          = "1.23.0"
  values = [
    <<-EOT
    meshConfig:
      accessLogFile: "/dev/stdout"
    EOT
  ]
}

# ----------------------------------------
# Install ArgoCD CRDs
# ----------------------------------------
resource "null_resource" "install_argocd_crds" {
  depends_on = [null_resource.wait_for_k8s]

  provisioner "local-exec" {
    command = <<EOT
      kubectl apply --validate=false -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.0/manifests/crds/application-crd.yaml
      kubectl apply --validate=false -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.0/manifests/crds/appproject-crd.yaml
      kubectl apply --validate=false -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.0/manifests/crds/applicationset-crd.yaml
    EOT
    interpreter = ["PowerShell", "-Command"]
  }
}

# ----------------------------------------
# ArgoCD Helm Release
# ----------------------------------------
resource "helm_release" "argocd" {
  depends_on       = [helm_release.istiod, null_resource.install_argocd_crds]
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600
  version          = "7.4.4"
}

# ----------------------------------------
# Wait for ArgoCD CRDs
# ----------------------------------------
resource "null_resource" "wait_for_argocd_crds" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = <<EOT
      $maxRetries=30
      $count=0
      while ($count -lt $maxRetries) {
        if (kubectl get crd applications.argoproj.io -o name) {
          Write-Output " ArgoCD CRDs are available."
          exit 0
        }
        Write-Output " Waiting for ArgoCD CRDs... retry $count"
        Start-Sleep -Seconds 10
        $count++
      }
      Write-Error "CRDs not available after waiting."
      exit 1
    EOT
    interpreter = ["PowerShell", "-Command"]
  }
}

# ----------------------------------------
# Prometheus and Grafana Helm Release
# ----------------------------------------
resource "helm_release" "prometheus" {
  depends_on       = [helm_release.istiod, null_resource.wait_for_k8s]
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
}

# ----------------------------------------
# ArgoCD Application
# ----------------------------------------
resource "kubernetes_manifest" "my_app_argocd" {
  depends_on = [null_resource.wait_for_argocd_crds]

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
