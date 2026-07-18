resource "oci_core_vcn" "gateway" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.42.0.0/16"]
  display_name   = "nitu-wa-gateway-vcn"
  dns_label      = "nituwagw"
}

resource "oci_core_internet_gateway" "gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.gateway.id
  display_name   = "nitu-wa-gateway-igw"
  enabled        = true
}

resource "oci_core_route_table" "gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.gateway.id
  display_name   = "nitu-wa-gateway-routes"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.gateway.id
  }
}

resource "oci_core_security_list" "gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.gateway.id
  display_name   = "nitu-wa-gateway-security"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
    description = "HTTP for ACME redirect and temporary setup"
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
    description = "HTTPS gateway"
  }

  ingress_security_rules {
    protocol = "17"
    source   = "0.0.0.0/0"
    udp_options {
      min = 443
      max = 443
    }
    description = "HTTP/3"
  }
}

resource "oci_core_subnet" "gateway" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.gateway.id
  cidr_block                 = "10.42.10.0/24"
  display_name               = "nitu-wa-gateway-public-subnet"
  dns_label                  = "gateway"
  route_table_id             = oci_core_route_table.gateway.id
  security_list_ids          = [oci_core_security_list.gateway.id]
  prohibit_public_ip_on_vnic = false
}
