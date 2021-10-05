provider "aws" {
  region = "eu-central-1"
}


data "aws_availability_zones" "available" {}

data "aws_ami" "latest_amazon_linux" {
  owners      = ["099720109477"]
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

data "aws_secretsmanager_secret_version" "creds" {
  # Fill in the name you gave to your secret
  secret_id = "db-secrets"
}

data "aws_secretsmanager_secret_version" "dd_api" {
  # Fill in the name you gave to your secret
  secret_id = "api_key"
}

locals {
  db_creds = jsondecode(
    data.aws_secretsmanager_secret_version.creds.secret_string
  )
  api = jsondecode(
    data.aws_secretsmanager_secret_version.dd_api.secret_string
  )
}

data "template_file" "task_definitions" {
  template = "${file("task-definitions/service.json")}"
  vars = {
    db_url = "${aws_db_instance.default.address}"
    cloudw = "${aws_cloudwatch_log_group.testapp_log_group.id}"
    api_key = "${local.api.api_key}"
  }
}
#--------------------------------------------------------------

resource "aws_security_group" "alb-sg" {
  name        = "testapp-load-balancer-security-group"
  description = "controls access to the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# this security group for ecs - Traffic to the ECS cluster should only come from the ALB
resource "aws_security_group" "ecs_sg" {
  name        = "testapp-ecs-tasks-security-group"
  description = "allow inbound access from the ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol        = "-1"
    from_port       = 0
    to_port         = 0
    security_groups = [aws_security_group.alb-sg.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name   = "db_security_group"
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group_rule" "db_rule" {
  type              = "ingress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.db.id
}

#----------------------------
resource "aws_ecs_cluster" "default" {
  name = "Petclinic"
}

resource "aws_ecs_task_definition" "test-def" {
  family                   = "testapp-task"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 2048
  memory                   = 4096
  container_definitions    = data.template_file.task_definitions.rendered
  volume {
    name = "docker_sock"
    host_path = "/var/run/docker.sock"
  }
  volume {
    name = "proc"
    host_path = "/proc/"
  }
  volume {
    name = "pointdir"
    host_path = "/opt/datadog-agent/run"
  }
  volume {
    name = "cgroup"
    host_path = "/cgroup/"
  }
}

resource "aws_ecs_service" "test-service" {
  name            = "testapp-service"
  cluster         = aws_ecs_cluster.default.id
  task_definition = aws_ecs_task_definition.test-def.arn
  desired_count   = 1

  network_configuration {
    security_groups  = [aws_security_group.ecs_sg.id]
    subnets          = [aws_subnet.pub_a.id,aws_subnet.pub_b.id]
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.myapp-tg.arn
    container_name   = "app"
    container_port   = 8080
  }

  depends_on = [aws_alb_listener.testapp, aws_iam_role_policy_attachment.ecs_task_execution_role]
}

#--------------------

data "aws_iam_policy_document" "ecs_task_execution_role" {
  statement {
    sid     = ""
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ECS task execution role
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "myECcsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_role.json
}

# ECS task execution role policy attachment
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

#------------------

resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 2
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.default.name}/${aws_ecs_service.test-service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

#Automatically scale capacity up by one
resource "aws_appautoscaling_policy" "ecs_policy_up" {
  name               = "scale-down"
  policy_type        = "StepScaling"
  resource_id        = "service/${aws_ecs_cluster.default.name}/${aws_ecs_service.test-service.name}"
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

#------------------

resource "aws_alb" "alb" {
  name           = "myapp-load-balancer"
  subnets        = [aws_subnet.pub_a.id, aws_subnet.pub_b.id]
  security_groups = [aws_security_group.alb-sg.id]
}

resource "aws_alb_target_group" "myapp-tg" {
  name        = "myapp-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 120
    protocol            = "HTTP"
    matcher             = "200"
    path                = "/"
    interval            = 300
  }
}

#redirecting all incomming traffic from ALB to the target group
resource "aws_alb_listener" "testapp" {
  load_balancer_arn = aws_alb.alb.id
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.myapp-tg.arn
  }
}

#------------------

resource "aws_cloudwatch_log_group" "testapp_log_group" {
  name              = "/ecs/testapp"
  retention_in_days = 30

  tags = {
    Name = "cw-log-group"
  }
}

resource "aws_cloudwatch_log_stream" "myapp_log_stream" {
  name           = "test-log-stream"
  log_group_name = aws_cloudwatch_log_group.testapp_log_group.name
}

#------------------

resource "aws_db_instance" "default" {
  allocated_storage      = 10
  engine                 = "mysql"
  engine_version         = "5.7"
  instance_class         = "db.t3.micro"
  name                   = "petclinic"
  username = local.db_creds.username
  password = local.db_creds.password
  parameter_group_name   = "default.mysql5.7"
  db_subnet_group_name   = aws_db_subnet_group.db_subnet.id
  vpc_security_group_ids = ["${aws_security_group.db.id}"]
  skip_final_snapshot    = true
}

#-----------------

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "My VPC"
  }
}

resource "aws_db_subnet_group" "db_subnet" {
  name       = "main"
  subnet_ids = [aws_subnet.pr_a.id, aws_subnet.pr_b.id]

  tags = {
    Name = "My DB subnet group"
  }
}

resource "aws_subnet" "pub_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "Public_a"
  }
  map_public_ip_on_launch = true
}

resource "aws_subnet" "pub_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  tags = {
    Name = "Public_b"
  }
  map_public_ip_on_launch = true
}

resource "aws_subnet" "pr_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "Private_a"
  }
}

resource "aws_subnet" "pr_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  tags = {
    Name = "Private_b"
  }
}

#------------

resource "aws_nat_gateway" "nat_a" {
  allocation_id = aws_eip.nat_eip_a.id
  subnet_id     = aws_subnet.pr_a.id
  depends_on    = [aws_internet_gateway.gw]
  tags = {
    Name = "nat"
  }
}
resource "aws_nat_gateway" "nat_b" {
  allocation_id = aws_eip.nat_eip_b.id
  subnet_id     = aws_subnet.pr_b.id
  depends_on    = [aws_internet_gateway.gw]
  tags = {
    Name = "nat"
  }
}
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main"
  }
}

#----------------

resource "aws_eip" "nat_eip_a" {
  vpc        = true
  depends_on = [aws_internet_gateway.gw]
}

resource "aws_eip" "nat_eip_b" {
  vpc        = true
  depends_on = [aws_internet_gateway.gw]
}

#------------

/* Routing table for private subnet */
resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.nat_a.id
  }
}
resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.nat_b.id
  }
}
/* Routing table for public subnet */
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

#---------------

/* Route table associations */
resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.pub_b.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.pr_a.id
  route_table_id = aws_route_table.private_a.id
}
resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.pr_b.id
  route_table_id = aws_route_table.private_b.id
}

#--------------------------------------------------

output "db" {
  value = aws_db_instance.default.address
}
