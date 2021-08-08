terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "3.52.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "2.46.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.1.0"
    }
  }
}

provider "aws" {
  shared_credentials_file = var.aws_cred_file
  region                  = var.aws_region
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_sub_id
}

resource "aws_vpc" "default" {
  cidr_block = "10.13.37.0/24"
}

resource "aws_internet_gateway" "default" {
  vpc_id = aws_vpc.default.id
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.default.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.default.id
}

resource "aws_subnet" "default" {
  vpc_id                  = aws_vpc.default.id
  cidr_block              = "10.13.37.0/24"
  availability_zone       = var.aws_az
  map_public_ip_on_launch = true
}

resource "aws_vpc_dhcp_options" "default" {
  domain_name_servers  = var.aws_dns_servers
}

resource "aws_vpc_dhcp_options_association" "default" {
  vpc_id          = aws_vpc.default.id
  dhcp_options_id = aws_vpc_dhcp_options.default.id
}

resource "aws_security_group" "mythic_server" {
  name        = "mythic_sg"
  vpc_id      = aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.aws_ip_allowlist
  }
  ingress {
    from_port   = 7443
    to_port     = 7443
    protocol    = "tcp"
    cidr_blocks = var.aws_ip_allowlist
  }
  ingress {
    from_port   = 81
    to_port     = 82
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

resource "aws_security_group" "elb_sg" {
  name        = "loadbal_sg"
  vpc_id      = aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
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

resource "aws_key_pair" "auth" {
  key_name   = var.public_key_name
  public_key = file(var.public_key_path)
}

resource "aws_instance" "mythic" {
  instance_type = var.aws_instance_type
  ami           = var.aws_ami

  tags = {
    "Name" = "${var.mythic_server_name}"
  }

  subnet_id              = aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.mythic_server.id]
  key_name               = aws_key_pair.auth.key_name
  private_ip             = "10.13.37.10"

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get -qq update && sudo apt-get -qq install -y git apt-transport-https ca-certificates curl gnupg lsb-release",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg",
      "echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get -qq update && sudo apt-get -qq install -y docker-ce docker-ce-cli docker-compose containerd.io",
      "sudo git clone https://github.com/its-a-feature/Mythic /opt/Mythic",
      "sudo /opt/Mythic/mythic-cli install github https://github.com/MythicAgents/atlas",
      "sudo /opt/Mythic/mythic-cli install github https://github.com/MythicAgents/Apollo",
      "sudo /opt/Mythic/mythic-cli install github https://github.com/MythicC2Profiles/http",
    ]

    connection {
      host        = self.public_ip
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }

  provisioner "file" {
      source = "../deps/http_config.json"
      destination = "/home/ubuntu/http_config.json"

      connection {
        host        = self.public_ip
        type        = "ssh"
        user        = "ubuntu"
        private_key = file(var.private_key_path)
      }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/ubuntu/http_config.json /opt/Mythic/C2_Profiles/http/c2_code/config.json",
      "export MYTHIC_ADMIN_USER=${var.mythic_user}",
      "export MYTHIC_ADMIN_PASSWORD=${var.mythic_password}",
      "export DEFAULT_OPERATION_NAME='${var.operation_name}'",
      "sudo -E /opt/Mythic/mythic-cli mythic start",
    ]

    connection {
      host        = self.public_ip
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
    }
  }

  root_block_device {
    delete_on_termination = true
    volume_type           = "gp3"
    volume_size           = 25
  }
}

resource "aws_elb" "aws_loadbal" {
  name               = "Mythic"
  subnets            = [aws_subnet.default.id]
  security_groups    = [aws_security_group.elb_sg.id]

  listener {
    instance_port     = 81
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 60
    target              = "TCP:81"
    interval            = 300
  }

  instances                   = [aws_instance.mythic.id]
  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400
}

resource "aws_cloudfront_distribution" "aws_cdn" {
  origin {
    domain_name = aws_elb.aws_loadbal.dns_name
    origin_id   = aws_elb.aws_loadbal.dns_name

    custom_origin_config {
      http_port              = "80"
      https_port             = "443"
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.1"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = false
  price_class = "PriceClass_200"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = aws_elb.aws_loadbal.dns_name

    forwarded_values {
      query_string = true
      headers      = ["*"]

      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "azurerm_resource_group" "azurecdn_resource" {
  name     = var.azurecdn_name
  location = var.azurecdn_loc
}

resource "azurerm_cdn_profile" "azurecdn_profile" {
  name                = var.azurecdn_name
  location            = azurerm_resource_group.azurecdn_resource.location
  resource_group_name = azurerm_resource_group.azurecdn_resource.name
  sku                 = "Standard_Microsoft"
}

resource "azurerm_cdn_endpoint" "azurecdn_endpoint" {
  name                          = var.azurecdn_name
  profile_name                  = azurerm_cdn_profile.azurecdn_profile.name
  location                      = azurerm_resource_group.azurecdn_resource.location
  resource_group_name           = azurerm_resource_group.azurecdn_resource.name
  origin_host_header            = aws_instance.mythic.public_ip
  querystring_caching_behaviour = "BypassCaching"

  origin {
    name       = var.azurecdn_name
    host_name  = aws_instance.mythic.public_ip
    http_port = "82"
  }

  delivery_rule {
    name = "nocache"
    order = 1
    query_string_condition {
      operator = "Any"
    }
    url_path_condition {
      operator = "Any"
    }
    cache_expiration_action {
      behavior = "BypassCache"
    }
  }

  depends_on = [
    aws_instance.mythic
  ]
}

resource "null_resource" "generate_payloads" {
  provisioner "local-exec" {
      command     = "python3 ../deps/generate_payloads.py"
      on_failure  = fail
      environment = {
        MYTHICIP   = aws_instance.mythic.public_ip,
        MYTHICUSER = var.mythic_user,
        MYTHICPASS = var.mythic_password,
        STAGEONE = format("http://%s",aws_cloudfront_distribution.aws_cdn.domain_name),
        STAGETWO = format("http://%s%s",var.azurecdn_name,".azureedge.net")
      }
  }

  depends_on = [
    aws_cloudfront_distribution.aws_cdn,
    azurerm_cdn_endpoint.azurecdn_endpoint
  ]
}
