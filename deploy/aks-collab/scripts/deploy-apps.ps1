param(
    [string]$Namespace = "collab-platform",
    [string]$IngressNamespace = "ingress-nginx",
    [string]$IngressServiceName = "ingress-nginx-controller"
)

$ErrorActionPreference = "Stop"

function Invoke-External {
    param([scriptblock]$Script)

    & $Script
    if ($LASTEXITCODE -ne 0) {
        throw "External command failed with exit code $LASTEXITCODE"
    }
}

function New-RandomPassword {
    param([int]$Length = 32)

    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $bytes = New-Object byte[] ($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Get-SecretValue {
    param(
        [string]$SecretName,
        [string]$Key
    )

    $encoded = & $script:kubectl -n $Namespace get secret $SecretName -o jsonpath="{.data.$Key}"
    if (-not $encoded) {
        throw "Missing key '$Key' in secret '$SecretName'"
    }

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
}

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$localDir = Join-Path $repoRoot "deploy/aks-collab/.local"
$generatedDir = Join-Path $localDir "generated"
$certDir = Join-Path $localDir "tls"
$statePath = Join-Path $localDir "app-secrets.json"
$kubectl = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Kubernetes.kubectl_Microsoft.Winget.Source_8wekyb3d8bbwe\kubectl.exe"
$helm = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Helm.Helm_Microsoft.Winget.Source_8wekyb3d8bbwe\windows-amd64\helm.exe"
$openssl = "C:\Program Files\Git\usr\bin\openssl.exe"

New-Item -ItemType Directory -Force -Path $localDir, $generatedDir, $certDir | Out-Null

$svc = & $kubectl -n $IngressNamespace get svc $IngressServiceName -o json | ConvertFrom-Json
$ip = $svc.status.loadBalancer.ingress[0].ip
if (-not $ip) {
    throw "Ingress controller does not have a public IP yet"
}

$domainSuffix = (($ip -replace '\.', '-') + '.nip.io')
$openprojectHost = "openproject.$domainSuffix"
$docmostHost = "docmost.$domainSuffix"
$passboltHost = "passbolt.$domainSuffix"

if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
} else {
    $state = [pscustomobject]@{}
}

if (-not $state.docmostAppSecret) {
    $state | Add-Member -NotePropertyName docmostAppSecret -NotePropertyValue (New-RandomPassword 48)
}
if (-not $state.passboltRedisPassword) {
    $state | Add-Member -NotePropertyName passboltRedisPassword -NotePropertyValue (New-RandomPassword 32)
}
$state | Add-Member -Force -NotePropertyName ingressIp -NotePropertyValue $ip
$state | Add-Member -Force -NotePropertyName domainSuffix -NotePropertyValue $domainSuffix
$state | ConvertTo-Json | Set-Content $statePath

$tlsSecretExists = $true
try {
    Invoke-External { & $kubectl -n $Namespace get secret collab-wildcard-tls | Out-Null }
} catch {
    $tlsSecretExists = $false
}

if (-not $tlsSecretExists -or $state.tlsDomainSuffix -ne $domainSuffix) {
    $opensslConfig = @"
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = *.$domainSuffix

[v3_req]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = *.$domainSuffix
DNS.2 = $domainSuffix
"@

    $configPath = Join-Path $certDir 'wildcard-nipio.cnf'
    $certPath = Join-Path $certDir 'wildcard-nipio.crt'
    $keyPath = Join-Path $certDir 'wildcard-nipio.key'

    Set-Content -Path $configPath -Value $opensslConfig -NoNewline
    Invoke-External { & $openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout $keyPath -out $certPath -config $configPath }
    Invoke-External { & $kubectl -n $Namespace create secret tls collab-wildcard-tls --cert $certPath --key $keyPath --dry-run=client -o yaml | & $kubectl apply -f - }
    $state | Add-Member -Force -NotePropertyName tlsDomainSuffix -NotePropertyValue $domainSuffix
    $state | ConvertTo-Json | Set-Content $statePath
}

$openprojectPassword = Get-SecretValue -SecretName 'openproject-db' -Key 'password'
$docmostPassword = Get-SecretValue -SecretName 'docmost-db' -Key 'password'
$passboltPassword = Get-SecretValue -SecretName 'passbolt-db' -Key 'password'
$docmostAppSecret = $state.docmostAppSecret
$passboltRedisPassword = $state.passboltRedisPassword

$openprojectValues = @"
ingress:
  enabled: true
  ingressClassName: nginx
  host: $openprojectHost
  tls:
    enabled: true
    secretName: collab-wildcard-tls

containerSecurityContext:
  readOnlyRootFilesystem: false

openproject:
  useTmpVolumes: false

persistence:
  enabled: true
  storageClassName: azurefile-csi
  accessModes:
    - ReadWriteMany

postgresql:
  bundled: false
  connection:
    host: collab-postgresql.$Namespace.svc.cluster.local
    port: 5432
  auth:
    existingSecret: openproject-db
    secretKeys:
      adminPasswordKey: password
      userPasswordKey: password
    username: openproject
    database: openproject
  options:
    sslmode: disable
"@

$docmostValues = @"
docmost:
  appUrl: https://$docmostHost
  appSecret: $docmostAppSecret

database:
  mode: external
  external:
    host: collab-postgresql.$Namespace.svc.cluster.local
    port: 5432
    name: docmost
    username: docmost
    existingSecret: docmost-db
    existingSecretPasswordKey: password

postgresql:
  enabled: false

ingress:
  enabled: true
  ingressClassName: nginx
  hosts:
    - host: $docmostHost
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - $docmostHost
      secretName: collab-wildcard-tls
"@

$passboltValues = @"
fullnameOverride: passbolt
replicaCount: 1

mariadbDependencyEnabled: false
postgresqlDependencyEnabled: false
redisDependencyEnabled: true

app:
  database:
    kind: postgresql
  cache:
    redis:
      enabled: true
      sentinelProxy:
        enabled: false
  tls:
    autogenerate: false
    existingSecret: collab-wildcard-tls

redis:
  auth:
    enabled: true
    password: $passboltRedisPassword
  sentinel:
    enabled: false

passboltEnv:
  plain:
    APP_FULL_BASE_URL: https://$passboltHost
    PASSBOLT_SSL_FORCE: true
    PASSBOLT_REGISTRATION_PUBLIC: true
    PASSBOLT_KEY_EMAIL: no-reply@$passboltHost
    EMAIL_DEFAULT_FROM: no-reply@$passboltHost
    EMAIL_DEFAULT_FROM_NAME: Passbolt
    EMAIL_TRANSPORT_DEFAULT_HOST: localhost
    EMAIL_TRANSPORT_DEFAULT_PORT: 587
    EMAIL_TRANSPORT_DEFAULT_TLS: false
    DATASOURCES_DEFAULT_HOST: collab-postgresql.$Namespace.svc.cluster.local
    DATASOURCES_DEFAULT_PORT: 5432
    CACHE_DEFAULT_HOST: passbolt-redis-master
    CACHE_CAKECORE_HOST: passbolt-redis-master
    CACHE_CAKEMODEL_HOST: passbolt-redis-master
    CACHE_DEFAULT_PORT: 6379
    CACHE_CAKECORE_PORT: 6379
    CACHE_CAKEMODEL_PORT: 6379
  secret:
    CACHE_DEFAULT_PASSWORD: $passboltRedisPassword
    CACHE_CAKECORE_PASSWORD: $passboltRedisPassword
    CACHE_CAKEMODEL_PASSWORD: $passboltRedisPassword
    DATASOURCES_DEFAULT_USERNAME: passbolt
    DATASOURCES_DEFAULT_PASSWORD: $passboltPassword
    DATASOURCES_DEFAULT_DATABASE: passbolt
    EMAIL_TRANSPORT_DEFAULT_USERNAME: ""
    EMAIL_TRANSPORT_DEFAULT_PASSWORD: ""

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
  hosts:
    - host: $passboltHost
      paths:
        - path: /
          port: https
          pathType: ImplementationSpecific
  tls:
    - autogenerate: false
      existingSecret: collab-wildcard-tls
      hosts:
        - $passboltHost

livenessProbe:
  httpGet:
    port: https
    scheme: HTTPS
    path: /healthcheck/status.json
    httpHeaders:
      - name: Host
        value: $passboltHost

readinessProbe:
  httpGet:
    port: https
    scheme: HTTPS
    path: /healthcheck/status.json
    httpHeaders:
      - name: Host
        value: $passboltHost
"@

$openprojectValuesPath = Join-Path $generatedDir 'openproject.values.yaml'
$docmostValuesPath = Join-Path $generatedDir 'docmost.values.yaml'
$passboltValuesPath = Join-Path $generatedDir 'passbolt.values.yaml'

Set-Content -Path $openprojectValuesPath -Value $openprojectValues -NoNewline
Set-Content -Path $docmostValuesPath -Value $docmostValues -NoNewline
Set-Content -Path $passboltValuesPath -Value $passboltValues -NoNewline

Invoke-External { & $helm upgrade --install openproject openproject/openproject --namespace $Namespace --create-namespace --version 13.8.0 -f $openprojectValuesPath --wait --timeout 30m }
Invoke-External { & $helm upgrade --install docmost helmforge/docmost --namespace $Namespace --version 1.2.1 -f $docmostValuesPath --wait --timeout 20m }
Invoke-External { & $helm upgrade --install passbolt passbolt-repo/passbolt --namespace $Namespace --version 2.1.0 -f $passboltValuesPath --wait --timeout 30m }

Invoke-External { & $kubectl -n $Namespace get ingress,pods,svc }

Write-Host "OpenProject: https://$openprojectHost"
Write-Host "Docmost: https://$docmostHost"
Write-Host "Passbolt: https://$passboltHost"
