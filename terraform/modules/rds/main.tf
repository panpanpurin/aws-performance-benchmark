resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-rds"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name      = "${var.name}-rds"
    Component = "rds"
  })
}

# Pinning the parameters that touch the measurement, instead of inheriting
# whatever the RDS default group happens to be for this engine version. The
# database configuration is then part of the artifact like everything else.
resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-anilove-pg"
  family = "postgres${split(".", var.engine_version)[0]}"

  # The AniLove scenario is create/update/delete per iteration, so the table
  # churns heavily while staying small.
  parameter {
    name         = "autovacuum_naptime"
    value        = "15"
    apply_method = "immediate"
  }

  # Let each pass finish quickly rather than throttling itself and dragging
  # across the measurement window.
  parameter {
    name         = "autovacuum_vacuum_cost_limit"
    value        = "2000"
    apply_method = "immediate"
  }

  # Only outliers: at the measured service times most queries are well under
  # this, so the log stays small and does not become its own I/O load.
  parameter {
    name         = "log_min_duration_statement"
    value        = "100"
    apply_method = "immediate"
  }

  # Without this, Performance Insights cannot attribute wait time to I/O.
  parameter {
    name         = "track_io_timing"
    value        = "1"
    apply_method = "immediate"
  }

  tags = merge(var.tags, {
    Name      = "${var.name}-anilove-pg"
    App       = "anilove"
    Component = "rds"
  })

  lifecycle {
    create_before_destroy = true
  }
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

  parameter_group_name = aws_db_parameter_group.this.name

  # Pinned so the database shares a zone with all three compute models.
  # Valid only because multi_az is false. See pin_compute_az in the root stack.
  availability_zone = var.availability_zone

  multi_az            = false
  publicly_accessible = false
  storage_encrypted   = true

  # Automated backups off. On Single-AZ the daily snapshot is an I/O pause, and
  # if the backup window lands inside a measurement run that repetition gets a
  # latency spike with no visible cause. The stack is destroyed after each
  # session and skip_final_snapshot is already true, so nothing is being kept.
  backup_retention_period = 0

  skip_final_snapshot        = true
  deletion_protection        = false
  apply_immediately          = true
  auto_minor_version_upgrade = false
  copy_tags_to_snapshot      = true

  # The database sits in the critical path of the only I/O-bound workload, and
  # all three platforms hit it in the same window. Performance Insights is what
  # turns "part of the database wait is mutual interference" from an assertion
  # into a measurement: DB load, connections and top SQL per run. 7 days of
  # retention is the free tier, which outlives a measurement session.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  tags = merge(var.tags, {
    Name      = "${var.name}-anilove"
    App       = "anilove"
    Component = "rds"
  })
}
