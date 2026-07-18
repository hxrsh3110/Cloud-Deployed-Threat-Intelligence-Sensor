provider "aws" {
  region = "eu-north-1"
}

resource "aws_security_group" "honeypot_sg" {
  name        = "launch-wizard-7"
  description = "launch-wizard-7 created 2026-07-06T10:49:50.673Z"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["27.59.103.156/32"]
  }

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

  tags = {
    Name = "honeypot"
  }
}

resource "aws_eip" "honeypot_eip" {
  instance = aws_instance.honeypot.id
  domain   = "vpc"
}