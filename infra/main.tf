provider "aws" {
  region = "eu-north-1"
}

resource "aws_security_group" "honeypot_sg" {
  name        = "launch-wizard-7"
  description = "launch-wizard-7 created 2026-07-06T10:49:50.673Z"

  ingress {
    description = "honeypot-trap"
    from_port   = 2222
    to_port     = 2222
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

resource "aws_instance" "honeypot" {
  ami                    = "ami-0aba19e56f3eaec05"
  instance_type          = "t3.micro"
  key_name               = "kharghar-server-key"
  vpc_security_group_ids = [aws_security_group.honeypot_sg.id]
  iam_instance_profile    = aws_iam_instance_profile.ssm_profile.name

  user_data                   = file("${path.module}/user_data.sh")
  user_data_replace_on_change = true

  tags = {
    Name = "honeypot"
  }
}

resource "aws_eip" "honeypot_eip" {
  instance = aws_instance.honeypot.id
  domain   = "vpc"
}

resource "aws_iam_role" "ssm_role" {
  name = "honeypot-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "honeypot-ssm-profile"
  role = aws_iam_role.ssm_role.name
}