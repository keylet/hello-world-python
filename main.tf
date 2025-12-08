# Proveedor de AWS
provider "aws" {
  region = "us-east-1"
}

# Grupo de Seguridad (Security Group)
resource "aws_security_group" "web_sg" {
  name        = "web_sg"
  description = "Allow inbound HTTP traffic"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Launch Template para las instancias EC2
resource "aws_launch_template" "example" {
  name_prefix   = "docker-launch-template-"
  image_id      = "ami-0fa3fe0fa7920f68e"  # Cambia por la AMI adecuada (Ubuntu, Amazon Linux 2, etc.)
  instance_type = "t2.micro"
  security_group_names = [aws_security_group.web_sg.name]

  user_data = <<-EOF
              #!/bin/bash
              docker run -d -p 80:80 keylet30/hello-world-python:latest
            EOF
}

# Auto Scaling Group (ASG)
resource "aws_autoscaling_group" "asg" {
  desired_capacity     = 5
  max_size             = 5
  min_size             = 5
  launch_template {
    launch_template_name = aws_launch_template.example.name
  }
  vpc_zone_identifier  = [
    "subnet-00ba1d368014ff92d",  # Subnet 1
    "subnet-06ba7208dd95414f0",  # Subnet 2
    "subnet-02042689e5e175b3a"   # Subnet 3
  ]
}

# Application Load Balancer (ALB)
resource "aws_lb" "app_lb" {
  name               = "app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [
    "subnet-00ba1d368014ff92d",
    "subnet-06ba7208dd95414f0",
    "subnet-02042689e5e175b3a"
  ]
}

# Target Group
resource "aws_lb_target_group" "app_target_group" {
  name     = "app-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "vpc-01cf9495523709023"  # VPC ID de tu cuenta
}

# Auto Scaling Attachment
resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.asg.name
  lb_target_group_arn  = aws_lb_target_group.app_target_group.arn
}

# Output de la URL del Load Balancer
output "load_balancer_url" {
  value = aws_lb.app_lb.dns_name
}
