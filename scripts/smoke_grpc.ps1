<#
.SYNOPSIS
    Corre el smoke gRPC (TestFlowPhx.Smoke.Grpc.RequestFlow) contra un servidor real.

.DESCRIPTION
    Asegura que protoc esté en el PATH, genera un script .exs temporal con los
    parámetros y lo ejecuta con `mix run`. Evita los problemas de comillas de
    pasar código Elixir por `mix run -e` en PowerShell.

    El cliente gRPC v1 es h2c / plaintext (sin TLS): el -Target debe aceptar
    conexión en claro.

.PARAMETER Mode
    discover | unary | stream | todos   (default: discover)
      discover : solo lista services/métodos del .proto (no conecta)
      unary    : envía un unary (-Service, -Method, -Body)
      stream   : envía un server stream (-Service, -Method, -Body)
      todos    : batería completa (discover + unary + unknown + bad_target,
                 y stream si se pasa -StreamMethod)

.EXAMPLE
    # Ver qué hay en el .proto (sin servidor)
    .\scripts\smoke_grpc.ps1 -Mode discover

.EXAMPLE
    # Probar un unary contra el server real
    .\scripts\smoke_grpc.ps1 -Mode unary -Method IniciarSesion `
        -Body '{"identificador":"test@example.com","contrasena":"secret"}'

.EXAMPLE
    # Batería completa
    .\scripts\smoke_grpc.ps1 -Mode todos -UnaryMethod IniciarSesion `
        -UnaryBody '{"identificador":"test@example.com","contrasena":"secret"}'
#>
[CmdletBinding()]
param(
    [ValidateSet('discover', 'unary', 'stream', 'todos')]
    [string]$Mode = 'discover',

    [string]$Target = 'localhost:9001',

    # Raíz desde donde se resuelven los `import` del .proto (estilo buf).
    [string]$ImportRoot = "$PSScriptRoot\..\docs\datos para pruebas",

    # .proto a cargar (relativo a ImportRoot o absoluto).
    [string]$Proto = 'donavida/auth/v1/auth.proto',

    [string]$Service = 'donavida.auth.v1.ServicioAutenticacion',

    # Para -Mode unary / stream:
    [string]$Method,
    [string]$Body = '{}',

    # Para -Mode todos:
    [string]$UnaryMethod,
    [string]$UnaryBody = '{}',
    [string]$StreamMethod,
    [string]$StreamBody = '{}',

    [int]$TimeoutMs = 15000,

    # Carpeta bin de protoc (si no está ya en el PATH).
    [string]$ProtocBin = "$env:USERPROFILE\protoc\bin"
)

$ErrorActionPreference = 'Stop'

# --- 1. protoc en el PATH ---------------------------------------------------
if (-not (Get-Command protoc -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $ProtocBin 'protoc.exe')) {
        $env:Path = $env:Path.TrimEnd(';') + ';' + $ProtocBin
    } else {
        throw "protoc no está en el PATH y no se encontró en '$ProtocBin'. Instalalo (ver docs/guias/smoke-grpc-windows.md) o pasá -ProtocBin."
    }
}
Write-Host ("protoc: " + (& protoc --version)) -ForegroundColor Cyan

# --- 2. Normalizar rutas a forward-slash (Elixir/protoc las aceptan) --------
$rootAbs  = (Resolve-Path -LiteralPath $ImportRoot).Path -replace '\\', '/'
$protoAbs =
    if ([System.IO.Path]::IsPathRooted($Proto)) { $Proto -replace '\\', '/' }
    else { "$rootAbs/$($Proto -replace '\\', '/')" }

if (-not (Test-Path -LiteralPath $protoAbs)) { throw "No existe el .proto: $protoAbs" }

# Helper: literal Elixir string seguro (escapa backslash y comillas dobles).
function Esc([string]$s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

# --- 3. Generar el .exs según el modo ---------------------------------------
$header = @"
alias TestFlowPhx.Smoke.Grpc.RequestFlow, as: G
root = $(Esc $rootAbs)
proto = $(Esc $protoAbs)
"@

$call = switch ($Mode) {
    'discover' {
        "G.discover(proto: proto, import_paths: [root])"
    }
    'unary' {
        if (-not $Method) { throw "-Mode unary requiere -Method" }
        "G.unary(target: $(Esc $Target), proto: proto, import_paths: [root], service: $(Esc $Service), method: $(Esc $Method), body: $(Esc $Body), timeout: $TimeoutMs)"
    }
    'stream' {
        if (-not $Method) { throw "-Mode stream requiere -Method" }
        "G.server_stream(target: $(Esc $Target), proto: proto, import_paths: [root], service: $(Esc $Service), method: $(Esc $Method), body: $(Esc $Body), timeout: $TimeoutMs)"
    }
    'todos' {
        if (-not $UnaryMethod) { throw "-Mode todos requiere -UnaryMethod" }
        $opts = "target: $(Esc $Target), proto: proto, import_paths: [root], service: $(Esc $Service), unary_method: $(Esc $UnaryMethod), unary_body: $(Esc $UnaryBody), timeout: $TimeoutMs"
        if ($StreamMethod) { $opts += ", stream_method: $(Esc $StreamMethod), stream_body: $(Esc $StreamBody)" }
        "G.todos($opts)"
    }
}

$exs     = "$header`n$call`n"
$tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("tf_smoke_" + [System.Guid]::NewGuid().ToString('N') + ".exs")
Set-Content -LiteralPath $tmpFile -Value $exs -Encoding UTF8

# --- 4. Correr ---------------------------------------------------------------
$projectRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..").Path
Push-Location $projectRoot
try {
    Write-Host "`n--- mix run ($Mode) ---`n" -ForegroundColor Cyan
    & mix run $tmpFile
} finally {
    Pop-Location
    Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
}
