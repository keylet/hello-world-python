# main.tf

# Proveedor de AWS
provider "aws" {
  region = "us-east-1"
}

# -----------------------------------------------------------------
# VARIABLES Y LOCALS
# -----------------------------------------------------------------

variable "environment" {
  description = "El entorno para el nombre de los recursos (por ejemplo, 'dev', 'prod')"
  type        = string
  default     = "dev" 
}

# Esta función genera un ID único en cada ejecución de 'apply',
# forzando a que los tags cambien y así Terraform no intente leer el TG.
locals {
  force_update_id = uuid() 
}

# -----------------------------------------------------------------
# 1. SEGURIDAD Y RED
# -----------------------------------------------------------------

# Grupo de Seguridad (Security Group)
resource "aws_security_group" "web_sg" {
  name        = "web-sg-${var.environment}" 
  description = "Allow inbound HTTP traffic from ALB and outbound all"
  vpc_id      = "vpc-01cf9495523709023"

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

  timeouts {
    delete = "3m"
  }
}

# -----------------------------------------------------------------
# 2. AUTO SCALING GROUP (ASG)
# -----------------------------------------------------------------

# Launch Template para las instancias EC2
resource "aws_launch_template" "example" {
  name_prefix   = "docker-launch-template-" 
  image_id      = "ami-0fa3fe0fa7920f68e" 
  instance_type = "t2.micro"
  
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install docker -y
              sudo service docker start
              
              sudo usermod -a -G docker ec2-user
              sleep 10
              
              # CORRECCIÓN DE PUERTOS: Mapear 80 (Host) a 80 (Contenedor Flask)
              docker run -d -p 80:80 keylet30/hello-world-python:latest
            EOF
  )
}

# Auto Scaling Group (ASG)
resource "aws_autoscaling_group" "asg" {
  desired_capacity    = 2
  max_size            = 7 
  min_size            = 2
  
  vpc_zone_identifier = [
    "subnet-00ba1d368014ff92d", 
    "subnet-06ba7208dd95414f0", 
    "subnet-02042689e5e175b3a"
  ]

  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest"
  }
  
  target_group_arns = [aws_lb_target_group.app_target_group.arn]

  health_check_type         = "EC2"
  health_check_grace_period = 300
  force_delete              = true
}

# -----------------------------------------------------------------
# 3. LOAD BALANCER (ALB)
# -----------------------------------------------------------------

# Target Group
resource "aws_lb_target_group" "app_target_group" {
  name     = "app-tg-${var.environment}"
  port     = 80 
  protocol = "HTTP"
  vpc_id   = "vpc-01cf9495523709023"
  
  # 🟢 SOLUCIÓN AL PERMISO DENEGADO: Forzar la actualización o recreación.
  tags = {
    ForceUpdateID = local.force_update_id
  }
  
  health_check {
    path = "/" 
    port = "traffic-port"
    protocol = "HTTP"
    interval = 30
    timeout = 5
    healthy_threshold = 2
    unhealthy_threshold = 2
    matcher = "200"
  }
}

# Load Balancer (ALB)
resource "aws_lb" "app_lb" {
  name                = "app-lb-${var.environment}"
  internal            = false
  load_balancer_type  = "application"
  security_groups     = [aws_security_group.web_sg.id]
  subnets             = [
    "subnet-00ba1d368014ff92d",
    "subnet-06ba7208dd95414f0",
    "subnet-02042689e5e175b3a"
  ]
}

# Listener para el Load Balancer
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_target_group.arn
  }
}

# -----------------------------------------------------------------
# 4. POLÍTICAS DE AUTO SCALING (CPU)
# -----------------------------------------------------------------

# 1. Política de Aumento de Capacidad (Scale Out)
resource "aws_autoscaling_policy" "scale_out_cpu" {
  name                   = "asg-scale-out-cpu-${var.environment}"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.asg.name
}

# Alarma de CloudWatch para activar el Scale Out (CPU alta)
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name                = "cpu-utilization-high-${var.environment}"
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  evaluation_periods        = 2
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/EC2"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 50
  alarm_description         = "Aumentar capacidad si CPU > 50% por 2 minutos"
  
  alarm_actions             = [aws_autoscaling_policy.scale_out_cpu.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

# 2. Política de Reducción de Capacidad (Scale In)
resource "aws_autoscaling_policy" "scale_in_cpu" {
  name                   = "asg-scale-in-cpu-${var.environment}"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.asg.name
}

# Alarma de CloudWatch para activar el Scale In (CPU baja)
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name                = "cpu-utilization-low-${var.environment}"
  comparison_operator       = "LessThanOrEqualToThreshold"
  evaluation_periods        = 2
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/EC2"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 10
  alarm_description         = "Reducir capacidad si CPU < 10% por 2 minutos"

  alarm_actions             = [aws_autoscaling_policy.scale_in_cpu.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

# -----------------------------------------------------------------
# 5. OUTPUTS
# -----------------------------------------------------------------

# Output de la URL del Load Balancer
output "load_balancer_url" {
  description = "URL del Application Load Balancer"
  value       = aws_lb.app_lb.dns_name
}
