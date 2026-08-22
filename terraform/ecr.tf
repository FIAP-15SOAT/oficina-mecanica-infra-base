resource "aws_ecr_repository" "ecr_app_repo" {
  name                 = local.ecr_app_repo_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = local.ecr_app_repo_name
  }
}

resource "aws_ecr_lifecycle_policy" "ecr_app_repo_lifecycle" {
  repository = aws_ecr_repository.ecr_app_repo.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 20 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
