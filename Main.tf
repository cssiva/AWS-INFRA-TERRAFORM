# Define the provider for AWS
provider "aws" {
  region = "us-east-1" # Replace with the desired AWS region
}

# Store Terraform state in an S3 bucket with DynamoDB for state locking
terraform {
  backend "s3" {
    bucket         = "terraform-state-bucket"  # Replace with your S3 bucket name
    key            = "terraform/state"        # Path to store the state file
    region         = "us-east-1"              # Region of the S3 bucket
    dynamodb_table = "terraform-state-lock"   # DynamoDB table for state locking
  }
}

# Step 1: Create a VPC (Virtual Private Cloud)
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16" # IP range for the VPC
  enable_dns_support   = true          # Enable DNS support
  enable_dns_hostnames = true          # Enable DNS hostnames
  tags = {
    Name = "MainVPC"
  }
}

# Step 2: Create public and private subnets
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24" # Public subnet range
  map_public_ip_on_launch = true          # Automatically assign public IPs to instances
  availability_zone       = "us-east-1a"  # Availability zone for the subnet
  tags = {
    Name = "PublicSubnet"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"  # Private subnet range
  availability_zone = "us-east-1a"   # Availability zone for the subnet
  tags = {
    Name = "PrivateSubnet"
  }
}

# Step 3: Create an Internet Gateway for public internet access
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "MainIGW"
  }
}

# Step 4: Set up a route table for the public subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"            # Route all traffic to the internet
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "PublicRouteTable"
  }
}

# Associate the public route table with the public subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Step 5: Create security groups
resource "aws_security_group" "app_sg" {
  name        = "AppSecurityGroup"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80                  # Allow HTTP traffic
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]       # Open to the internet
  }

  ingress {
    from_port   = 22                  # Allow SSH access
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]       # Open to the internet
  }

  egress {
    from_port   = 0                   # Allow all outbound traffic
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "AppSecurityGroup"
  }
}

# Step 6: Launch EC2 instances with auto-scaling
resource "aws_launch_configuration" "app" {
  name          = "AppLaunchConfig"
  image_id      = "ami-12345678" # Replace with the desired AMI ID
  instance_type = "t2.micro"    # Instance type
  security_groups = [
    aws_security_group.app_sg.id
  ]
  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    systemctl start httpd
    systemctl enable httpd
  EOF
}

resource "aws_autoscaling_group" "app_asg" {
  launch_configuration = aws_launch_configuration.app.id
  min_size             = 1
  max_size             = 3
  desired_capacity     = 2
  vpc_zone_identifier  = [aws_subnet.public.id]

  tags = [{
    key                 = "Name"
    value               = "AppInstance"
    propagate_at_launch = true
  }]
}

# Step 7: Deploy an Application Load Balancer
resource "aws_lb" "app_lb" {
  name               = "AppLoadBalancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.app_sg.id]
  subnets            = [aws_subnet.public.id]

  tags = {
    Name = "AppLoadBalancer"
  }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "AppTargetGroup"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# Step 8: Set up an RDS instance
resource "aws_db_instance" "app_db" {
  allocated_storage    = 20
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t2.micro"
  name                 = "appdb"
  username             = "admin"
  password             = "password123" # Replace with a secure password
  skip_final_snapshot  = true
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  subnet_group_name    = aws_db_subnet_group.db_subnet_group.name
}

resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "db-subnet-group"
  subnet_ids = [aws_subnet.private.id]

  tags = {
    Name = "DBSubnetGroup"
  }
}
