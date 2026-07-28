resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-rds"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name      = "${var.name}-rds"
    Component = "rds"
  })
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-anilove"

  engine               = "postgres"
  engine_version       = var.engine_version
  instance_class       = var.instance_class
  allocated_storage    = var.allocated_storage
  storage_type         = "gp3"
  db_name              = var.db_name
  username             = var.username
  password             = var.password
  port                 = 5432
  db_subnet_group_name = aws_db_subnet_group.this.name
  vpc_security_group_ids = [
    var.security_group_id,
  ]

  multi_az                     = false
  publicly_accessible          = false
  storage_encrypted            = true
  backup_retention_period      = 1
  skip_final_snapshot          = true
  deletion_protection          = false
  apply_immediately            = true
  performance_insights_enabled = false
  auto_minor_version_upgrade   = false
  copy_tags_to_snapshot        = true

  tags = merge(var.tags, {
    Name      = "${var.name}-anilove"
    App       = "anilove"
    Component = "rds"
  })
}
