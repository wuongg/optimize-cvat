# Replaces the resident rqscheduler process. Each job is idempotent, so
# running all five every hour is safe. A failed job stops the rest and
# returns its exit code.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

$jobs = @(
    "clean_up_sessions",
    "cron_export_cache_directory_cleanup",
    "cron_tmp_directory_cleanup",
    "cron_instance_tmp_directories_cleanup",
    "clear_unusable_access_tokens"
)

foreach ($job in $jobs) {
    docker compose exec -T cvat_worker_utils django-admin runperiodicjob $job
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
