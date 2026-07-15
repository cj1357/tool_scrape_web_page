[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $scriptRoot 'cleaned_data'
}
$python = Get-Command python -ErrorAction Stop

& $python.Source (Join-Path $scriptRoot 'clean_articles.py') `
    --root $scriptRoot `
    --output $OutputDirectory

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
