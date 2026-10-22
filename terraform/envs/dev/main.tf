# dev: single region, same module as prod (smaller and cheaper: one NAT gateway).
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
  backend "s3" {
    bucket         = "orderflow-tfstate-example"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "orderflow-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Project = "orderflow", Environment = "dev", Owner = "platform" }
  }
}

module "region" {
  source      = "../../modules/region"
  name        = "orderflow-dev-use1"
  azs         = ["us-east-1a", "us-east-1b", "us-east-1c"]
  environment = "dev"
  vpc_cidr    = "10.40.0.0/16"
}
