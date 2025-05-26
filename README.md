Steps to replicate

1. `terraform init`
2. `terraform apply --auto-approve`
3. Update main.tf -> line 327 to `machine_type            = "n2-standard-2"`
4. `terraform apply --auto-approve`

Error looks like:
```
│ Error: Provider produced inconsistent final plan
│ 
│ When expanding the plan for module.slurm_controller.module.slurm_files.google_storage_bucket_object.nodeset_config["debugnodeset"] to include new values learned so
│ far during apply, provider "registry.terraform.io/hashicorp/google" produced an invalid new value for .crc32c: was known, but now unknown.
│ 
│ This is a bug in the provider, which should be reported in the provider's own issue tracker.
╵
╷
│ Error: Provider produced inconsistent final plan
│ 
│ When expanding the plan for module.slurm_controller.module.slurm_files.google_storage_bucket_object.nodeset_config["debugnodeset"] to include new values learned so
│ far during apply, provider "registry.terraform.io/hashicorp/google" produced an invalid new value for .md5hash: was known, but now unknown.
│ 
│ This is a bug in the provider, which should be reported in the provider's own issue tracker.
╵
╷
│ Error: Provider produced inconsistent final plan
│ 
│ When expanding the plan for module.slurm_controller.module.slurm_files.google_storage_bucket_object.nodeset_config["debugnodeset"] to include new values learned so
│ far during apply, provider "registry.terraform.io/hashicorp/google" produced an invalid new value for .generation: was known, but now unknown.
│ 
│ This is a bug in the provider, which should be reported in the provider's own issue tracker.
```
