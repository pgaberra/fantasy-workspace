# Klonar de sex fantasy-tjänsterna in i den här mappen.
# Kör efter att workspace-repot klonats på en ny maskin:
#   powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1

$ErrorActionPreference = 'Stop'

$repos = @(
  'fantasy-web',
  'fantasy-bff',
  'fantasy-db-service',
  'fantasy-yahoo-service',
  'fantasy-espn-service',
  'fantasy-projection-service'
)

foreach ($r in $repos) {
  $dest = Join-Path $PSScriptRoot $r
  if (Test-Path $dest) {
    Write-Host "$r finns redan - hoppar over"
    continue
  }
  Write-Host "Klonar $r ..."
  git clone "git@github.com:pgaberra/$r.git" $dest
}

Write-Host ""
Write-Host "Klart. Aterstar manuellt:"
Write-Host "  1. Kopiera ~/.postgres-mcp (pgpass.conf + scripten) fran den andra maskinen."
Write-Host "  2. Justera sokvagarna i .mcp.json om hemkatalogen heter nagot annat har."
Write-Host "  3. Satt env-variablerna for bootRun (DB_PASSWORD, INTERNAL_API_KEY m.fl.)."
