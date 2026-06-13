# Packages install log

This file records the shell commands I ran on this machine while installing and verifying Terraform and Azure CLI.

## 1) Initial checks

```powershell
winget --version
where.exe winget
```

## 2) First install attempt (combined)

```powershell
winget install --id HashiCorp.Terraform -e --accept-package-agreements --accept-source-agreements && winget install --id Microsoft.AzureCLI -e --accept-package-agreements --accept-source-agreements
```

Result:
- attempted with elevated execution
- blocked because elevated execution was not available in this runtime

## 3) Terraform install attempts

```powershell
winget install --id HashiCorp.Terraform -e --accept-package-agreements --accept-source-agreements
winget install --id Hashicorp.Terraform -e --source winget --accept-package-agreements --accept-source-agreements
```

Related discovery commands:

```powershell
winget search terraform --source winget
```

## 4) Azure CLI discovery and install attempts

```powershell
winget search --id Microsoft.AzureCLI --source winget
winget search azure cli --source winget
winget search azure --source winget
winget install --id Microsoft.AzureCLI -e --source winget --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.AzureCLI -e --source winget --scope user --accept-package-agreements --accept-source-agreements
```

Result:
- package was found
- installer download started
- MSI install ended with exit code `1602` (installation canceled)
- per-user install then reported no applicable installer found

## 5) Diagnostic checks during Azure CLI install

```powershell
Get-Process msiexec -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,StartTime
where.exe az
```

## 6) Extra environment checks

```powershell
python --version
py --version
pip --version
```

## 7) Terraform verification and path inspection

```powershell
where.exe terraform
terraform version
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory | Where-Object { $_.Name -like 'Hashicorp.Terraform*' } | Select-Object -ExpandProperty FullName
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Links" | Select-Object Name,FullName
Get-ChildItem -Recurse "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe" | Select-Object FullName
Get-ChildItem -Recurse "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe" | ForEach-Object { $_.FullName }
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe\terraform.exe" version
```

## 8) Azure CLI path check

```powershell
if (Test-Path "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd") { Write-Output "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd" } elseif (Test-Path "$env:LOCALAPPDATA\Programs\Azure CLI\wbin\az.cmd") { Write-Output "$env:LOCALAPPDATA\Programs\Azure CLI\wbin\az.cmd" } else { Write-Output "missing" }
```

## Summary

- Terraform installation succeeded
- Verified version: `v1.15.6`
- Azure CLI installation did not complete successfully yet
