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

data "template_file" "user_data" {
  template = file("/Users/mac/DevOps/petclinic/user_data.sh")
  vars = {
    db_url = aws_db_instance.default.address
  }
}

/*locals {
  vars = {
    db_url = aws_db_instance.default.address
  }
}*/
#--------------------------------------------------------------
resource "aws_security_group" "web" {
  name       = "Dynamic Security Group"
  vpc_id     = aws_vpc.main.id
  depends_on = [aws_vpc.main]

  dynamic "ingress" {
    for_each = ["80", "22", "8080"]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Dynamic SecurityGroup"
  }
}

/*
resource "aws_security_group" "db" {
  name = "db_security_group"
  vpc_id="${aws_vpc.main.id}"
  depends_on  = [aws_vpc.main]
  ingress {
    from_port = 3306
    to_port = 3306
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
*/

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

resource "aws_launch_configuration" "web" {
  //  name            = "WebServer-Highly-Available-LC"
  name_prefix     = "WebServer-Highly-Available-LC-"
  image_id        = data.aws_ami.latest_amazon_linux.id
  instance_type   = "t2.medium"
  security_groups = [aws_security_group.web.id]
  user_data       = data.template_file.user_data.rendered
  depends_on      = [aws_db_instance.default]
}



resource "aws_autoscaling_group" "web" {
  name                 = "ASG-${aws_launch_configuration.web.name}"
  launch_configuration = aws_launch_configuration.web.name
  min_size             = 2
  max_size             = 2
  min_elb_capacity     = 2
  health_check_type    = "ELB"
  vpc_zone_identifier  = [aws_subnet.pub_a.id, aws_subnet.pub_b.id]
  load_balancers       = [aws_elb.web.name]
  depends_on           = [aws_db_instance.default]
  dynamic "tag" {
    for_each = {
      Name   = "WebServer in ASG"
      TAGKEY = "TAGVALUE"
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }

}


resource "aws_elb" "web" {
  name            = "WebServer-HA-ELB"
  security_groups = [aws_security_group.web.id]
  subnets         = [aws_subnet.pub_a.id, aws_subnet.pub_b.id]
  listener {
    lb_port           = 80
    lb_protocol       = "http"
    instance_port     = 8080
    instance_protocol = "http"
  }
  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 10
  }
  tags = {
    Name = "WebServer-Highly-Available-ELB"
  }
}

resource "aws_db_instance" "default" {
  allocated_storage      = 10
  engine                 = "mysql"
  engine_version         = "5.7"
  instance_class         = "db.t3.micro"
  name                   = "petclinic"
  username               = var.username
  password               = var.password
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

#------------------

#resource "aws_route" "public_internet_gateway" {
#  route_table_id         = "${aws_route_table.public.id}"
#  destination_cidr_block = "0.0.0.0/0"
#  gateway_id             = "${aws_internet_gateway.gw.id}"
#}
#resource "aws_route" "private_nat_gateway_a" {
#  route_table_id         = "${aws_route_table.private_a.id}"
#  destination_cidr_block = "0.0.0.0/0"
#  nat_gateway_id         = "${aws_nat_gateway.nat_a.id}"
#}
#resource "aws_route" "private_nat_gateway_b" {
#  route_table_id         = "${aws_route_table.private.id}"
#  destination_cidr_block = "0.0.0.0/0"
#  nat_gateway_id         = "${aws_nat_gateway.nat_b.id}"
#}

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

output "web_loadbalancer_url" {
  value = aws_elb.web.dns_name
}

output "db" {
  value = aws_db_instance.default.address
}
