-- All placeholders are complete SQL literals quoted by generate_migration.py.
SELECT cron.schedule_in_database(
    {job_name},
    {schedule},
    {command},
    {database}
);
