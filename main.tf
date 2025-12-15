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

locals {
  force_update_id = uuid()
}

# -----------------------------------------------------------------
# 1. SEGURIDAD Y RED
# -----------------------------------------------------------------

# Grupo de Seguridad (Security Group)
resource "aws_security_group" "web_sg" {
  name        = "web-sg-${var.environment}"
  description = "Allow inbound HTTP traffic from ALB and SSH for deployment"
  vpc_id      = "vpc-01cf9495523709023" # Reemplaza con tu VPC ID

  # Reglas de acceso HTTP (puerto 80)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Reglas de acceso SSH (puerto 22)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------------
# 2. CREAR CLAVE SSH
# -----------------------------------------------------------------

# Crea la clave SSH en AWS usando tu clave pública local
resource "aws_key_pair" "hello_python_key" {
  key_name   = "Hello-python"
  public_key = file("~/.ssh/id_rsa.pub") 
}

# -----------------------------------------------------------------
# 3. INSTANCIAS EC2 Y AUTO SCALING GROUP
# -----------------------------------------------------------------

# Launch Template para las instancias EC2
resource "aws_launch_template" "example" {
  name_prefix   = "docker-launch-template-"
  image_id      = "ami-0fa3fe0fa7920f68e" # Amazon Linux 2 AMI
  instance_type = "t3.micro"
  key_name      = aws_key_pair.hello_python_key.key_name
  
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  # CORRECCIÓN DE ARGUMENTO: Usando 'user_data'
  user_data = base64encode(<<-EOF
               #!/bin/bash
               sudo yum update -y
               sudo yum install docker -y
               sudo service docker start
               
               # Añadir el usuario al grupo docker y permitir acceso al socket
               sudo usermod -a -G docker ec2-user
               sudo chmod 666 /var/run/docker.sock 
               
               sleep 10
             EOF
  )
}

# Auto Scaling Group (ASG)
resource "aws_autoscaling_group" "asg" {
  desired_capacity    = 2
  max_size            = 7
  min_size            = 2
  
  # SUBREDES CORREGIDAS
  vpc_zone_identifier = [
    "subnet-00ba1d368014ff92d",
    "subnet-06ba7208dd95414f0",
    "subnet-0a1e57e2d09e7b66d" # Reemplazada por una válida de tu entorno
  ]

  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.app_target_group.arn]

  health_check_type         = "EC2"
  health_check_grace_period = 300
  force_delete              = true
  
  tag {
    key                 = "ASG-Name"
    value               = "asg"
    propagate_at_launch = true
  }
}

# -----------------------------------------------------------------
# 4. LOAD BALANCER (ALB)
# -----------------------------------------------------------------

# Target Group (Puerto 80 para el Health Check)
resource "aws_lb_target_group" "app_target_group" {
  name     = "app-tg-${var.environment}"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "vpc-01cf9495523709023" 
  
  tags = {
    ForceUpdateID = local.force_update_id
  }
  
  health_check {
    path                = "/" 
    port                = "traffic-port"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

# Load Balancer (ALB)
resource "aws_lb" "app_lb" {
  name                = "app-lb-${var.environment}"
  internal            = false
  load_balancer_type  = "application"
  security_groups     = [aws_security_group.web_sg.id]
  
  # SUBREDES CORREGIDAS
  subnets             = [
    "subnet-00ba1d368014ff92d",
    "subnet-06ba7208dd95414f0",
    "subnet-0a1e57e2d09e7b66d" # Reemplazada por una válida de tu entorno
  ]
}

# Listener para el Load Balancer (Escuchando en el puerto 80)
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
# 5. POLÍTICAS DE AUTO SCALING (CPU)
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
  alarm_name          = "cpu-utilization-high-${var.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "Aumentar capacidad si CPU > 50% por 2 minutos"
  
  alarm_actions       = [aws_autoscaling_policy.scale_out_cpu.arn]

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
  alarm_name          = "cpu-utilization-low-${var.environment}"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 10
  alarm_description   = "Reducir capacidad si CPU < 10% por 2 minutos"

  alarm_actions       = [aws_autoscaling_policy.scale_in_cpu.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

# -----------------------------------------------------------------
# 6. OUTPUTS
# -----------------------------------------------------------------

# Output de la URL del Load Balancer
output "load_balancer_url" {
  description = "URL del Application Load Balancer"
  value       = aws_lb.app_lb.dns_name
}