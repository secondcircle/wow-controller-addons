# Publishes a new download for the shared addons.
#   .\release.ps1 1.0.1 "what changed"
# Commits and pushes any changes to PartyDiamond / SoftTarget / README, then creates a GitHub
# release with one zip that unzips straight into Interface\AddOns.
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Notes = ""
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = "C:\Program Files\GitHub CLI\gh.exe" }

git add -A
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
  $msg = "Release $Version"
  if ($Notes) { $msg = "$msg`: $Notes" }
  git commit -m $msg
}
git push origin main

$zip = Join-Path $env:TEMP "wow-controller-addons-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "PartyDiamond", "SoftTarget" -DestinationPath $zip

if ($Notes) {
  & $gh release create "v$Version" $zip --title "v$Version" --notes $Notes
} else {
  & $gh release create "v$Version" $zip --title "v$Version" --generate-notes
}
Remove-Item $zip
