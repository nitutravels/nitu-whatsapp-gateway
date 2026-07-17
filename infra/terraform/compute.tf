resource "oci_core_instance" "gateway" {
  availability_domain = local.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "nitu-whatsapp-gateway"
  shape               = var.instance_shape
  preserve_boot_volume = true

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.gateway.id
    assign_public_ip = false
    display_name     = "nitu-wa-primary-vnic"
    hostname_label   = "wagateway"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gbs
  }

  metadata = {
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      env_file_b64 = base64encode(local.env_file)
    }))
    gateway_env_b64 = base64encode(local.env_file)
  }

  freeform_tags = {
    Application = "Nitu WhatsApp Gateway"
    ManagedBy   = "Terraform"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [source_details[0].source_id]
  }
}

data "oci_core_vnic_attachments" "gateway" {
  compartment_id = var.compartment_ocid
  instance_id     = oci_core_instance.gateway.id
}

data "oci_core_vnic" "gateway" {
  vnic_id = data.oci_core_vnic_attachments.gateway.vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "gateway" {
  vnic_id = data.oci_core_vnic.gateway.id
}

resource "oci_core_public_ip" "gateway" {
  compartment_id = var.compartment_ocid
  display_name   = "nitu-wa-gateway-reserved-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.gateway.private_ips[0].id
}
