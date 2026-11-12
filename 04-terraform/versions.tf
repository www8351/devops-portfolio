terraform {
  # Checked with 1.17.2. The range stops before 2.0, which may change the language.
  required_version = ">= 1.9, < 2.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # One exact version, so every init gets the same provider.
      # .terraform.lock.hcl records its checksums.
      version = "= 6.73.0"
    }
  }
}
