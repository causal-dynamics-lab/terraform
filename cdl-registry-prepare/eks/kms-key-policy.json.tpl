{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnableIAMPolicies",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${account_id}:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "DenyCielaraDeployerSignAndAdmin",
      "Effect": "Deny",
      "Principal": { "AWS": "*" },
      "Action": [
        "kms:Sign",
        "kms:CreateGrant",
        "kms:PutKeyPolicy",
        "kms:ScheduleKeyDeletion",
        "kms:DisableKey",
        "kms:UpdateAlias",
        "kms:DeleteAlias"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:PrincipalArn": [
            "arn:aws:iam::${account_id}:role/cielara_deployer",
            "arn:aws:sts::${account_id}:assumed-role/cielara_deployer/*",
            "arn:aws:iam::${account_id}:role/cielara_eks_deployer_*",
            "arn:aws:sts::${account_id}:assumed-role/cielara_eks_deployer_*/*"
          ]
        }
      }
    }
  ]
}
