terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.32.0"
    }
  }
}

variable "DO_TOKEN" {
  sensitive = true
}
variable "CERT_NAME" {
  default = "certname"
  sensitive = true
}
variable "DOMAIN" {
  default = "sub.example.eu"
  sensitive = true
}
variable "CODER_VERSION" {
  default = "2.4.0"
}

provider "digitalocean" {
  token = var.DO_TOKEN
}

data "digitalocean_kubernetes_versions" "coder" {
  version_prefix = "1.28."
}

data "digitalocean_region" "coder" {
  slug = "fra1"
}

data "digitalocean_project" "coder" {
  name = "coder"
}

resource "digitalocean_project_resources" "coder" {
  project = data.digitalocean_project.coder.id
  resources = [
    digitalocean_vpc.coder.urn,
    digitalocean_kubernetes_cluster.coder.urn,
    digitalocean_database_cluster.coder.urn,
    digitalocean_domain.coder.urn,
    digitalocean_loadbalancer.coder.urn
  ]
}

resource "digitalocean_vpc" "coder" {
  name   = "coder-network"
  region = data.digitalocean_region.coder.slug
}

resource "digitalocean_kubernetes_cluster" "coder" {
  name = "coder-kubernetes-cluster"
  region = data.digitalocean_region.coder.slug
  auto_upgrade = true
  version = data.digitalocean_kubernetes_versions.coder.latest_version
  vpc_uuid = digitalocean_vpc.coder.id

  maintenance_policy {
    start_time = "04:00"
    day = "sunday"
  }

  node_pool {
    name = "coder-pool"
    size = "s-1vcpu-2gb"
    node_count = 1
  }
}

resource "digitalocean_database_cluster" "coder" {
  name = "coder-database-cluster"
  engine = "pg"
  version = "15"
  size = "db-s-1vcpu-1gb"
  region = data.digitalocean_region.coder.slug
  node_count = 1
  private_network_uuid = digitalocean_vpc.coder.id

  maintenance_window {
    hour = "04:00"
    day = "sunday"
  }
}

resource "digitalocean_database_firewall" "coder-database-fw" {
  cluster_id = digitalocean_database_cluster.coder.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.coder.id
  }
}

resource "digitalocean_loadbalancer" "coder" {
  name = "coder-loadbalancer"
  region = data.digitalocean_region.coder.slug

  forwarding_rule {
    entry_port = 443
    entry_protocol = "https"

    target_port = 80
    target_protocol = "http"

    certificate_name = var.CERT_NAME
  }
}

resource "digitalocean_domain" "coder" {
  name = "coder.${var.DOMAIN}"
  ip_address = digitalocean_loadbalancer.coder.ip
}

# provider "kubernetes" {
#  host = digitalocean_kubernetes_cluster.coder.endpoint
#  token = digitalocean_kubernetes_cluster.coder.kube_config[0].token
#  cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.coder.kube_config[0].cluster_ca_certificate)
# }

resource "kubernetes_namespace" "coder" {
  metadata {
    name = "coder"
  }
}

provider "helm" {
  kubernetes {
    host = digitalocean_kubernetes_cluster.coder.endpoint
    token = digitalocean_kubernetes_cluster.coder.kube_config[0].token
    cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.coder.kube_config[0].cluster_ca_certificate)
  }
}

resource "helm_release" "coder" {
  name = "coder"
  namespace = kubernetes_namespace.coder.metadata.0.name
  chart = "https://github.com/coder/coder/releases/download/v${var.CODER_VERSION}/coder_helm_${var.CODER_VERSION}.tgz"
  depends_on = [
    digitalocean_database_cluster.coder
  ]

  set {
    name = "coder.env[0].name"
    value = "CODER_PG_CONNECTION_URL"
  }
  set {
    name = "coder.env[0].value"
    value = digitalocean_database_cluster.coder.private_uri
  }

  set {
    name = "coder.env[1].name"
    value = "CODER_TELEMETRY"
  }
  set {
    name = "coder.env[1].value"
    value = false
  }

  set {
    name = "coder.env[2].name"
    value = "CODER_ACCESS_URL"
  }
  set {
    name = "coder.env[2].value"
    value = "https://coder.${var.DOMAIN}"
  }

  set {
    name = "coder.env[3].name"
    value = "CODER_WILDCARD_ACCESS_URL"
  }
  set {
    name = "coder.env[3].value"
    value = "*.coder.${var.DOMAIN}"
  }
}
