Steps to replicate

1. `terraform init`
2. `terraform apply --auto-approve`
3. Update main.tf -> line 327 to `machine_type            = "n2-standard-1"`
4. `terraform apply --auto-approve`
