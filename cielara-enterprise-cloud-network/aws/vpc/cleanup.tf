#################################################
# Destroy-time cleanup of deleted-cluster leftovers
#
# A Cielara EKS cluster in this network can leave two things behind after it
# is deleted, outside any terraform state: detached VPC CNI network interfaces
# (they block deleting the subnets) and the EKS cluster security group (it
# blocks deleting the VPC). On `terraform destroy` this resource goes first —
# it references the VPC and subnets — and its script removes only those
# leftovers: tagged for a `cdl-` Cielara cluster that EKS reports as gone,
# inside this VPC. See cleanup-cluster-leftovers.sh.
#
# Never runs on apply. Best effort: without the aws CLI, bash or the IAM
# permissions it prints the manual steps and destroy carries on as before.
#
# A destroy-time provisioner can only read `self`, so everything it needs is
# captured in `input` at apply time. `input` changes update in place (there is
# no triggers_replace), so an apply never runs the cleanup.
#################################################
resource "terraform_data" "cluster_leftovers" {
  input = {
    region     = var.region
    vpc_id     = aws_vpc.main.id
    subnet_ids = join(",", concat(aws_subnet.private[*].id, aws_subnet.public[*].id))
    script     = "${path.module}/cleanup-cluster-leftovers.sh"
    bash       = local.bash
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = [self.input.bash, "-c"]
    command     = "bash '${self.input.script}' '${self.input.region}' '${self.input.vpc_id}' '${self.input.subnet_ids}'"
    on_failure  = continue
  }
}
