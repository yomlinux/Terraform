terraform {
  required_version = ">= 1.5.0"
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = ">= 2.5.0"
    }
  }
}

provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = true
}

# ------------------ Variables ------------------
variable "vsphere_user"     { default = "administrator@dnixx.comm" }
variable "vsphere_password" { sensitive = true }
variable "vsphere_server"   { default = "10.0.0.120" }

variable "dc_name"          { default = "DNIXX" }
variable "esxi_host_name"   { default = "10.0.0.121" } # standalone ESXi host
variable "datastore_name"   { default = "proddata1" }
variable "network_name"     { default = "VM Network" }

variable "template_path"    { default = "/DNIXX/vm/test" }
variable "vm_domain"        { default = "dnixx.comm" }

# Static IPs for VMs
variable "static_ips" {
  type = map(string)
  default = {
    "k8s-master-1" = "10.0.0.131"
    "k8s-worker-1" = "10.0.0.132"
    "k8s-worker-2" = "10.0.0.133"
  }
}

locals {
  nodes = {
    "k8s-master-1" = { role = "master", cpu = 2, memory_mb = 8192 }
    "k8s-worker-1" = { role = "worker", cpu = 2, memory_mb = 4096 }
    "k8s-worker-2" = { role = "worker", cpu = 2, memory_mb = 4096 }
  }
}

# ------------------ Data Lookups ------------------
data "vsphere_datacenter" "dc" {
  name = var.dc_name
}

data "vsphere_host" "esxi" {
  name          = var.esxi_host_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "ds" {
  name          = var.datastore_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "net" {
  name          = var.network_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  datacenter_id = data.vsphere_datacenter.dc.id
  name          = var.template_path
}

# ------------------ VM Resources ------------------
resource "vsphere_virtual_machine" "k8s" {
  for_each         = local.nodes

  name             = each.key
  resource_pool_id = data.vsphere_host.esxi.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id

  num_cpus = each.value.cpu
  memory   = each.value.memory_mb
  guest_id = data.vsphere_virtual_machine.template.guest_id
  scsi_type = data.vsphere_virtual_machine.template.scsi_type
  firmware = "efi"  # Enables EFI to fix ACPI errors

  network_interface {
    network_id   = data.vsphere_network.net.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "disk0"
    size             = data.vsphere_virtual_machine.template.disks[0].size
    thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id

    customize {
      linux_options {
        host_name = each.key
        domain    = var.vm_domain
      }

      network_interface {
        ipv4_address = var.static_ips[each.key]
        ipv4_netmask = 24
      }

      ipv4_gateway = "10.0.0.1"
    }
  }
}

# ------------------ Outputs ------------------
output "k8s_nodes" {
  description = "VM names and roles"
  value = { for k, v in local.nodes : k => v.role }
}
