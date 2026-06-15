param(
    [string]$Namespace = "collab-platform",
    [string]$ReleaseName = "collab-postgresql",
    [string]$ChartVersion = "18.7.3"
)

$ErrorActionPreference = "Stop"

function New-RandomPassword {
    param([int]$Length = 32)

    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^*-_"
    $bytes = New-Object byte[] ($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Invoke-External {
    param([scriptblock]$Script)

    & $Script
    if ($LASTEXITCODE -ne 0) {
        throw "External command failed with exit code $LASTEXITCODE"
    }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$valuesFile = Join-Path $repoRoot "deploy/aks-collab/postgresql/values.yaml"
$kubectl = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Kubernetes.kubectl_Microsoft.Winget.Source_8wekyb3d8bbwe\kubectl.exe"
$helm = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Helm.Helm_Microsoft.Winget.Source_8wekyb3d8bbwe\windows-amd64\helm.exe"

Invoke-External { & $kubectl create namespace $Namespace --dry-run=client -o yaml | & $kubectl apply -f - }

$existingPassword = $null
try {
    $existingPassword = (& $kubectl -n $Namespace get secret collab-postgresql-auth -o jsonpath="{.data.postgres-password}" 2>$null)
} catch {}

if (-not $existingPassword) {
    $postgresPassword = New-RandomPassword
    Invoke-External { & $kubectl -n $Namespace create secret generic collab-postgresql-auth `
        --from-literal=postgres-password=$postgresPassword `
        --dry-run=client -o yaml | & $kubectl apply -f - }
    Write-Host "Created collab-postgresql-auth secret in namespace $Namespace"
} else {
    Write-Host "Reusing existing collab-postgresql-auth secret in namespace $Namespace"
}

Invoke-External { & $helm upgrade --install $ReleaseName bitnami/postgresql `
    --namespace $Namespace `
    --version $ChartVersion `
    --values $valuesFile }

Invoke-External { & $kubectl -n $Namespace rollout status statefulset/collab-postgresql --timeout=10m }
Invoke-External { & $kubectl -n $Namespace get svc,pods -l app.kubernetes.io/instance=$ReleaseName }
