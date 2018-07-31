module "ssh_keypair_aws_override" {
  source = "github.com/hashicorp-modules/ssh-keypair-aws"

  create = "${var.create}"
  name   = "${var.name}-override"
}

data "aws_ami" "base" {
  most_recent = true
  owners      = ["${var.ami_owner}"]

  filter {
    name   = "name"
    values = ["${var.ami_name}"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "template_file" "base_install" {
  template = "${file("${path.module}/../../templates/install-base.sh.tpl")}"
}

data "template_file" "consul_install" {
  template = "${file("${path.module}/../../templates/install-consul-systemd.sh.tpl")}"

  vars = {
    consul_version  = "${var.consul_version}"
    consul_url      = "${var.consul_url}"
    name            = "${var.name}"
    local_ip_url    = "${var.local_ip_url}"
    consul_override = "${var.consul_config_override != "" ? true : false}"
    consul_config   = "${var.consul_config_override}"
  }
}

module "network_aws" {
  # source = "github.com/hashicorp-modules/network-aws"
  source = "../../../../../../hashicorp-modules/network-aws"

  create            = "${var.create}"
  name              = "${var.name}"
  vpc_cidr          = "${var.vpc_cidr}"
  vpc_cidrs_public  = "${var.vpc_cidrs_public}"
  nat_count         = "${var.nat_count}"
  vpc_cidrs_private = "${var.vpc_cidrs_private}"
  bastion_count     = "${var.bastion_servers}"
  os                = "${replace(lower(var.ami_name), "ubuntu", "") != lower(var.ami_name) ? "Ubuntu" : replace(lower(var.ami_name), "rhel", "") != lower(var.ami_name) ? "RHEL" : "unknown"}"
  image_id          = "${var.bastion_image_id != "" ? var.bastion_image_id : data.aws_ami.base.id}"
  private_key_file  = "${module.ssh_keypair_aws_override.private_key_filename}"
  tags              = "${var.network_tags}"
}

data "http" "workstation_external_ip" {
  url = "http://icanhazip.com"
}

locals {
  workstation_external_cidr = "${chomp(data.http.workstation_external_ip.body)}/32"
}

resource "random_string" "wetty_password" {
  count = "${var.create ? 1 : 0}"

  length           = 32
  special          = true
  override_special = "${var.override}"
}

data "template_file" "wetty_install" {
  template = "${file("${path.module}/../../templates/install-wetty.sh.tpl")}"

  vars = {
    wetty_user = "wetty-${var.name}"
    wetty_pass = "${element(concat(random_string.wetty_password.*.result, list("")), 0)}" # TODO: Workaround for issue #11210
  }
}

module "consul_aws" {
  # source = "github.com/hashicorp-modules/consul-aws"
  source = "../../../../../../hashicorp-modules/consul-aws"

  create        = "${var.create}"
  name          = "${var.name}" # Must match network_aws module name for Consul Auto Join to work
  vpc_id        = "${module.network_aws.vpc_id}"
  vpc_cidr      = "${module.network_aws.vpc_cidr}"
  subnet_ids    = "${split(",", var.consul_public ? join(",", module.network_aws.subnet_public_ids) : join(",", module.network_aws.subnet_private_ids))}"
  count         = "${var.consul_servers}"
  instance_type = "${var.consul_instance}"
  os            = "${replace(lower(var.ami_name), "ubuntu", "") != lower(var.ami_name) ? "Ubuntu" : replace(lower(var.ami_name), "rhel", "") != lower(var.ami_name) ? "RHEL" : "unknown"}"
  image_id      = "${var.consul_image_id != "" ? var.consul_image_id : data.aws_ami.base.id}"
  cidr_blocks   = "${split(",", var.consul_public ? join(",", compact(concat(list(local.workstation_external_cidr), var.public_cidrs, list(module.network_aws.vpc_cidr)))) : module.network_aws.vpc_cidr)}" # If there's a public IP, open Consul ports for public access - DO NOT DO THIS IN PROD
  public        = "${var.consul_public}"
  ssh_key_name  = "${module.ssh_keypair_aws_override.name}"
  tags          = "${var.consul_tags}"
  tags_list     = "${var.consul_tags_list}"

  user_data = <<EOF
${data.template_file.base_install.rendered} # Runtime install base tools
${data.template_file.consul_install.rendered} # Runtime install Consul in -dev mode
${data.template_file.wetty_install.rendered} # Runtime install Wetty
EOF
}

resource "aws_security_group_rule" "wetty_tcp" {
  count = "${var.create && var.consul_public ? 1 : 0}"

  security_group_id = "${module.consul_aws.consul_sg_id}"
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 3030
  to_port           = 3030
  cidr_blocks       = ["${compact(concat(list(local.workstation_external_cidr), var.public_cidrs))}"]
  description       = "Wetty inbound TCP traffic"
}
