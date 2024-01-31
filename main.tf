provider "aws" {
  region = "us-east-1"
}

# Obtener el VPC ID de la VPC "default"
data "aws_vpc" "default" {
  filter {
    name   = "isDefault"
    values = ["true"]
  }
}

# Obtener los IDs de las subredes en la VPC "default"
data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

# Crear Security Groups
resource "aws_security_group" "sg_linux" {
  name        = "SG-Linux"
  description = "Security Group for Linux instances"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group" "sg_efs" {
  name        = "SG-EFS"
  description = "Security Group for EFS"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group" "sg_alb" {
  name        = "SG-ALB"
  description = "Security Group for Application Load Balance"
  vpc_id      = data.aws_vpc.default.id
}

# Reglas SG-Linux
resource "aws_security_group_rule" "sg_linux_ingress_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sg_linux.id
}

resource "aws_security_group_rule" "sg_linux_ingress_http" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sg_alb.id
  security_group_id        = aws_security_group.sg_linux.id
}

resource "aws_security_group_rule" "sg_linux_ingress_nfs" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sg_efs.id
  security_group_id        = aws_security_group.sg_linux.id
}

# Reglas SG-EFS
resource "aws_security_group_rule" "sg_efs_ingress_nfs" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sg_linux.id
  security_group_id        = aws_security_group.sg_efs.id
}

# Reglas SG-ALB
resource "aws_security_group_rule" "sg_alb_ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sg_alb.id
}

# Crear bucket de S3
resource "aws_s3_bucket" "tay5111" {
  bucket = "tay5111"
}

resource "aws_s3_bucket_public_access_block" "tay5111" {
  bucket = aws_s3_bucket.tay5111.bucket
  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "tay5111" {
  bucket = aws_s3_bucket.tay5111.bucket

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "arn:aws:s3:::${aws_s3_bucket.tay5111.bucket}/*"
    }]
  })
}

resource "aws_s3_bucket_object" "index_php" {
  bucket = aws_s3_bucket.tay5111.bucket
  key    = "index.php"
  source = "index.php"
}

# EFS
resource "aws_efs_file_system" "webserver" {
  creation_token         = "token"
  performance_mode       = "generalPurpose"
  throughput_mode        = "bursting"
  encrypted              = true
  tags = {
    Name = "webserver_EFS"
  }
}

resource "aws_efs_mount_target" "webserver" {
  count           = length(data.aws_subnet_ids.default.ids)
  file_system_id  = aws_efs_file_system.webserver.id
  subnet_id       = data.aws_subnet_ids.default.ids[count.index]
  security_groups = [aws_security_group.sg_efs.id]
}

# Crear archivo user_data
data "template_file" "user_data" {
  template = <<-EOF
    #!/bin/bash
    yum install -y httpd php wget
    systemctl start httpd
    systemctl enable httpd

    sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${aws_efs_file_system.webserver.dns_name}:/ /var/www/html

    sudo wget -nc https://${aws_s3_bucket.tay5111.bucket}.s3.amazonaws.com/index.php -P /var/www/html/
  EOF
}

# Obtener IDs de las subredes en cada zona de disponibilidad
data "aws_availability_zones" "available" {}

resource "aws_instance" "webserver" {
  count                      = length(data.aws_subnet_ids.default.ids)
  ami                        = "ami-0a3c3a20c09d6f377" // Replace with actual AMI ID
  instance_type              = "t2.micro"
  subnet_id                  = element(data.aws_subnet_ids.default.ids, count.index)
  associate_public_ip_address = true
  user_data                  = data.template_file.user_data.rendered
  tags = {
    Name = "webserver-${element(data.aws_availability_zones.available.names, count.index)}"
  }
}

# ALB
resource "aws_lb" "webserver" {
  name               = "webserver-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = data.aws_subnet_ids.default.ids
  security_groups    = [aws_security_group.sg_alb.id]
}

resource "aws_lb_target_group" "webserver" {
  name        = "webserver-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"
}

resource "aws_lb_listener" "webserver" {
  load_balancer_arn = aws_lb.webserver.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webserver.arn
  }
}

output "alb_dns_name" {
  value = aws_lb.webserver.dns_name
}
