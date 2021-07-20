# AWS infrastructure resources

# used to ssh into ec2 instances to make sure they're ready to progress rancher deployment
data "local_file" "rancher_dev_pem" {
  filename = "${path.module}/rancher-dev.pem"
}

data "aws_security_group" "corp_sgs" {
  for_each = var.corp_security_group_names
  name = each.key
}

resource "aws_security_group" "rancher_nodes" {
  name   = "rancher-nodes"
  vpc_id = var.vpc_id
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }
}

# AWS EC2 instance for creating a single node RKE cluster and installing the Rancher server
resource "aws_instance" "rancher_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  key_name = var.keypair_name
  vpc_security_group_ids = concat([for sg in data.aws_security_group.corp_sgs : sg.id], [aws_security_group.rancher_nodes.id])
  subnet_id = var.subnet_id

  user_data = templatefile(
    join("/", [path.module, "../cloud-common/files/userdata_rancher_server.template"]),
    {
      docker_version = var.docker_version
      username       = local.node_username
    }
  )

  root_block_device {
    volume_size = 16
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait > /dev/null",
      "echo 'Completed cloud-init!'",
    ]

    connection {
      type = "ssh"
      host = self.public_ip
      user = local.node_username
      private_key = file("${path.module}/rancher-dev.pem")
    }
  }

  tags = {
    Name    = "${var.prefix}-rancher-server"
    Creator = "rancher-quickstart"
  }
}

# Rancher resources
module "rancher_common" {
  source = "../rancher-common"

  node_public_ip   = aws_instance.rancher_server.public_ip
  node_internal_ip = aws_instance.rancher_server.private_ip
  node_username    = local.node_username
  ssh_private_key_pem    = data.local_file.rancher_dev_pem.content
  rke_kubernetes_version = var.rke_kubernetes_version

  cert_manager_version = var.cert_manager_version
  rancher_version      = var.rancher_version

  rancher_server_dns = aws_instance.rancher_server.public_dns

  admin_password = var.rancher_server_admin_password

  workload_kubernetes_version = var.workload_kubernetes_version
  workload_cluster_name       = "quickstart-aws-custom"
}

# AWS EC2 instance for creating a single node workload cluster
resource "aws_instance" "quickstart_node" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  key_name = var.keypair_name
  vpc_security_group_ids = concat([for sg in data.aws_security_group.corp_sgs : sg.id], [aws_security_group.rancher_nodes.id])
  subnet_id = var.subnet_id

  user_data = templatefile(
    join("/", [path.module, "files/userdata_quickstart_node.template"]),
    {
      docker_version   = var.docker_version
      username         = local.node_username
      register_command = module.rancher_common.custom_cluster_command
    }
  )

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait > /dev/null",
      "echo 'Completed cloud-init!'",
    ]

    connection {
      type = "ssh"
      host = self.public_ip
      user = local.node_username
      private_key = data.local_file.rancher_dev_pem.content
    }
  }

  tags = {
    Name    = "${var.prefix}-quickstart-node"
    Creator = "rancher-quickstart"
  }
}
