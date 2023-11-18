terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.32.0"
    }
  }
}

# variable "do_token" {}
variable "do_cert_name" {
  default = "certname"
}
variable "app_domain" {
  default = "sub.example.eu"
}
variable "db_user" {
  default = "coder"
}
variable "db_password" {
  default = "password"
}
variable "db_database" {
  default = "coder"
}
variable "coder_version" {
  default = "2.4.0"
}

provider "digitalocean" {
  token = var.do_token
}

data "digitalocean_certificate" "cert" {
  name = var.do_cert_name
}

data "digitalocean_kubernetes_versions" "coder" {
  version_prefix = "1.28."
}

data "digitalocean_region" "coder" {
  slug = "fra1"
}

resource "digitalocean_vpc" "coder" {
  name   = "coder-network"
  region = data.digitalocean_region.coder
}

resource "digitalocean_kubernetes_cluster" "coder" {
  name = "coder-kubernetes-cluster"
  region = data.digitalocean_region.coder
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
  region = data.digitalocean_region.coder
  node_count = 1
  user = var.db_user
  password = var.db_password
  database = var.db_database
  private_network_uuid = digitalocean_vpc.network.id

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

resource "digitalocean_domain" "default" {
  name = "coder.${var.domain}"
  ip_address = digitalocean_kubernetes_cluster.coder.ipv4_address
}

data "digitalocean_certificate" "coder" {
  name = var.do_wildcard_cert_name
}

resource "digitalocean_loadbalancer" "coder" {
  name = "coder-loadbalancer"
  region = data.digitalocean_region.coder

  forwarding_rule {
    entry_port = 443
    entry_protocol = "https"

    target_port = 80
    target_protocol = "http"

    certificate_name = digitalocean_certificate.cert.name
  }
}

provider "kubernetes" {
  host = digitalocean_kubernetes_cluster.coder.endpoint
  token = digitalocean_kubernetes_cluster.coder.kube_config[0].token
  cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.coder.kube_config[0].cluster_ca_certificate)
}

resource "kubernetes_namespace" "coder" {
  metadata {
    name = "coder"
  }
}

provider "helm" {
  host = digitalocean_kubernetes_cluster.coder.endpoint
  token = digitalocean_kubernetes_cluster.coder.kube_config[0].token
  cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.coder.kube_config[0].cluster_ca_certificate)
}

resource "helm_release" "coder" {
  name = "coder"
  namespace = kubernetes_namespace.coder.metadata.0.name
  chart = "https://github.com/coder/coder/releases/download/v${var.coder_version}/coder_helm_${var.coder_version}.tgz"
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
    value = "https://coder.${var.domain}"
  }

  set {
    name = "coder.env[3].name"
    value = "CODER_WILDCARD_ACCESS_URL"
  }
  set {
    name = "coder.env[3].value"
    value = "*.coder.${var.domain}"
  }
}
