#Requires -RunAsAdministrator
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serviceName = 'MoonlightManagedHostAgent'
$installRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'MoonlightManagedAccess'))
$policyFile = Join-Path $installRoot 'policy\managed-policy.json'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this helper from an elevated Windows PowerShell session.'
}

function Assert-NoReparseSegments([string]$Path) {
    $candidate = [IO.Path]::GetFullPath($Path)
    while ($candidate) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to operate through a reparse point: $candidate"
            }
        }
        $parent = Split-Path -LiteralPath $candidate -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $candidate) {
            break
        }
        $candidate = $parent
    }
}

Assert-NoReparseSegments $installRoot
Assert-NoReparseSegments $policyFile

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $service) {
    if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $serviceName -Force
    }
    Set-Service -Name $serviceName -StartupType Disabled
}

if (Test-Path -LiteralPath $policyFile) {
    Remove-Item -LiteralPath $policyFile -Force
}

Write-Host 'Managed host access is disabled locally. The agent is stopped and its current lease policy has been removed.'
