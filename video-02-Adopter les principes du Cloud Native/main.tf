provider "aws" {
  region = "eu-west-3"
}

# Recherche de l'AMI Ubuntu la plus récente
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

# Crée un groupe de sécurité pour autoriser l'accès SSH
resource "aws_security_group" "ssh_sg" {
  name        = "ssh-access-sg"
  description = "Allow SSH inbound traffic"

  # Règle d'entrée pour le port 22 (SSH)
  ingress {
    description = "Allow SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    # IMPORTANT : Remplacez "0.0.0.0/0" par votre adresse IP publique pour plus de sécurité
    # Si vous n'êtes pas sur de votre IP, vous pouvez utiliser un service comme "whatismyip.com"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Règle de sortie par défaut pour autoriser tout le trafic sortant
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ssh-access-sg"
  }
}

# Crée une paire de clés SSH
resource "tls_private_key" "rsa_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "key_pair" {
  key_name   = "ec2-docker-key"
  public_key = tls_private_key.rsa_key.public_key_openssh
}

# Sauvegarde de la clé privée localement et ajuste ses permissions
resource "local_file" "private_key" {
  content  = tls_private_key.rsa_key.private_key_pem
  filename = "ec2-docker-key.pem"
}

resource "null_resource" "key_permissions" {
  provisioner "local-exec" {
    command = "chmod 400 ec2-docker-key.pem"
  }

  depends_on = [
    local_file.private_key
  ]
}

# Crée l'instance EC2 et y associe le groupe de sécurité et la clé SSH
resource "aws_instance" "docker_ec2_instance" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.key_pair.key_name

  # Associe le groupe de sécurité à l'instance
  vpc_security_group_ids = [aws_security_group.ssh_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update -y
              sudo apt-get install \
                  ca-certificates \
                  curl \
                  gnupg \
                  -y
              sudo install -m 0755 -d /etc/apt/keyrings
              curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
              sudo chmod a+r /etc/apt/keyrings/docker.gpg
              echo \
                "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
              sudo apt-get update -y
              sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
              sudo usermod -aG docker ubuntu
              # Section pour JDK 17 et Maven
              # Installation de la version par défaut de l'Open JDK 17
              sudo apt-get install -y openjdk-17-jdk

              # Installation de Maven
              sudo apt-get install -y maven

              # Vérification des installations (facultatif, mais utile pour le debug)
              java --version
              mvn --version
              EOF

  tags = {
    Name = "docker-ec2-instance-paris"
  }
}

output "instance_public_ip" {
  description = "L'adresse IP publique de l'instance EC2."
  value       = aws_instance.docker_ec2_instance.public_ip
}
