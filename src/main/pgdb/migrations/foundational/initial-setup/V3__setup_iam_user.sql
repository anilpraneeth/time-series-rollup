-- Create IAM user and grant required role
CREATE USER db_ecs_user;
GRANT rds_iam TO db_ecs_user; 