-- Create schemas for data warehouse layers
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS partman;

-- Create archive schemas for each layer
CREATE SCHEMA IF NOT EXISTS raw_archive;
CREATE SCHEMA IF NOT EXISTS silver_archive;
CREATE SCHEMA IF NOT EXISTS gold_archive; 