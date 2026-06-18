variable "aws_region" {
  default = "us-west-2"
}

resource "aws_iam_policy" "eso_read" {
  name = "ESO-SecretsManager-Read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = ["*"]
    }]
  })
}

resource "aws_iam_user" "eso_sync" {
  name = "eso-sync"
}

resource "aws_iam_user_policy_attachment" "eso_attach" {
  user       = aws_iam_user.eso_sync.name
  policy_arn = aws_iam_policy.eso_read.arn
}

resource "aws_iam_access_key" "eso_sync_key" {
  user = aws_iam_user.eso_sync.name
}

resource "aws_secretsmanager_secret" "db_password" {
  name = "w10/db-password"
}

resource "aws_secretsmanager_secret_version" "db_password_val" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = "admin"
    password = "P@ssw0rd123"
  })
}

output "access_key_id" {
  value = aws_iam_access_key.eso_sync_key.id
}

output "secret_access_key" {
  value     = aws_iam_access_key.eso_sync_key.secret
  sensitive = true
}
