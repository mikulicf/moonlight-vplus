#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BackendUrl,

    [Parameter(Mandatory = $true)]
    [Security.SecureString]$HostToken,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AgentExecutable,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ApolloConfig,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerCertificate,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ApolloReadAccount,

    [ValidateRange(1, 65535)]
    [int]$HttpPort = 47989,

    [ValidateNotNullOrEmpty()]
    [string]$ApolloServiceName = 'ApolloService'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$agentServiceName = 'MoonlightManagedHostAgent'
$installRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'MoonlightManagedAccess'))
$binDirectory = Join-Path $installRoot 'bin'
$privateDirectory = Join-Path $installRoot 'private'
$policyDirectory = Join-Path $installRoot 'policy'
$backupDirectory = Join-Path $installRoot 'backup'
$installedAgent = Join-Path $binDirectory 'moonlight-agent.exe'
$agentConfig = Join-Path $privateDirectory 'agent.json'
$policyFile = Join-Path $policyDirectory 'managed-policy.json'
$stateFile = Join-Path $privateDirectory 'install-state.json'
$backupFile = Join-Path $backupDirectory 'apollo-config.pre-managed'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this installer from an elevated Windows PowerShell session.'
    }
}

function Get-FullLiteralPath([string]$Path, [bool]$MustExist) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($MustExist -and -not (Test-Path -LiteralPath $full)) {
        throw "Required path does not exist: $full"
    }
    return $full
}

function Assert-NoReparseSegments([string]$Path) {
    $candidate = [IO.Path]::GetFullPath($Path)
    while ($candidate) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in installer paths: $candidate"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $candidate) {
            break
        }
        $candidate = $parent
    }
}

function Assert-UnderInstallRoot([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $installRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a managed write outside the install root: $full"
    }
}

function Resolve-AccountSid([string]$Account) {
    switch ($Account.Trim().ToUpperInvariant()) {
        'LOCALSYSTEM' { return New-Object Security.Principal.SecurityIdentifier('S-1-5-18') }
        'NT AUTHORITY\SYSTEM' { return New-Object Security.Principal.SecurityIdentifier('S-1-5-18') }
        'LOCALSERVICE' { return New-Object Security.Principal.SecurityIdentifier('S-1-5-19') }
        'NT AUTHORITY\LOCAL SERVICE' { return New-Object Security.Principal.SecurityIdentifier('S-1-5-19') }
        'NETWORKSERVICE' { return New-Object Security.Principal.SecurityIdentifier('S-1-5-20') }
        'NT AUTHORITY\NETWORK SERVICE' { return New-Object Security.Principal.SecurityIdentifier('S-1-5-20') }
    }
    try {
        return (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier])
    }
    catch {
        throw "Windows account could not be resolved: $Account"
    }
}

function Assert-SupportedApolloAccount([Security.Principal.SecurityIdentifier]$Sid) {
    if ($Sid.Value -eq 'S-1-5-18') {
        # Apollo's Windows service wrapper normally runs as LocalSystem and
        # launches the console-session process with a duplicated SYSTEM token.
        return
    }
    $forbidden = @(
        'S-1-5-19',
        'S-1-5-20',
        'S-1-5-32-544'
    )
    if ($forbidden -contains $Sid.Value) {
        throw 'ApolloReadAccount must be LocalSystem or a dedicated non-administrator account, not LocalService, NetworkService, or Administrators.'
    }

    $localGroupCommand = Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue
    if ($null -ne $localGroupCommand) {
        $administratorGroup = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
        $administratorMembers = Get-LocalGroupMember -Group $administratorGroup -ErrorAction Stop
        if ($administratorMembers.SID.Value -contains $Sid.Value) {
            throw 'ApolloReadAccount is a member of the local Administrators group and cannot be restricted to policy read access.'
        }
    }
}

function Add-FileSystemRule(
    [Security.AccessControl.FileSystemSecurity]$Acl,
    [Security.Principal.IdentityReference]$Identity,
    [Security.AccessControl.FileSystemRights]$Rights,
    [Security.AccessControl.InheritanceFlags]$Inheritance,
    [Security.AccessControl.PropagationFlags]$Propagation
) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        $Identity,
        $Rights,
        $Inheritance,
        $Propagation,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$Acl.AddAccessRule($rule)
}

function Set-PrivateDirectoryAcl([string]$Path, [Security.Principal.SecurityIdentifier]$ApolloSid, [bool]$AllowApolloTraverse) {
    $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $administratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($systemSid)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    Add-FileSystemRule $acl $systemSid ([Security.AccessControl.FileSystemRights]::FullControl) $inherit $none
    Add-FileSystemRule $acl $administratorsSid ([Security.AccessControl.FileSystemRights]::FullControl) $inherit $none
    if ($AllowApolloTraverse -and $ApolloSid.Value -ne $systemSid.Value) {
        Add-FileSystemRule $acl $ApolloSid ([Security.AccessControl.FileSystemRights]::ExecuteFile) ([Security.AccessControl.InheritanceFlags]::None) $none
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-PolicyDirectoryAcl([string]$Path, [Security.Principal.SecurityIdentifier]$ApolloSid) {
    $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $administratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($systemSid)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    Add-FileSystemRule $acl $systemSid ([Security.AccessControl.FileSystemRights]::FullControl) $inherit $none
    Add-FileSystemRule $acl $administratorsSid ([Security.AccessControl.FileSystemRights]::FullControl) $inherit $none
    if ($ApolloSid.Value -ne $systemSid.Value) {
        Add-FileSystemRule $acl $ApolloSid ([Security.AccessControl.FileSystemRights]::ReadAndExecute) $inherit $none
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-PrivateFileAcl([string]$Path) {
    $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $administratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($systemSid)
    $none = [Security.AccessControl.InheritanceFlags]::None
    $propagation = [Security.AccessControl.PropagationFlags]::None
    Add-FileSystemRule $acl $systemSid ([Security.AccessControl.FileSystemRights]::FullControl) $none $propagation
    Add-FileSystemRule $acl $administratorsSid ([Security.AccessControl.FileSystemRights]::FullControl) $none $propagation
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-Utf8FileAtomic([string]$Path, [string]$Contents) {
    Assert-UnderInstallRoot $Path
    Assert-NoReparseSegments $Path
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.write-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Assert-UnderInstallRoot $temporary
    try {
        [IO.File]::WriteAllText($temporary, $Contents, (New-Object Text.UTF8Encoding($false)))
        Set-PrivateFileAcl $temporary
        Move-Item -LiteralPath $temporary -Destination $Path -Force
        Set-PrivateFileAcl $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-ApolloDirective([string]$Contents) {
    $matches = [regex]::Matches($Contents, '(?m)^[ \t]*managed_policy_file[ \t]*=.*$')
    if ($matches.Count -gt 1) {
        throw 'Apollo configuration contains more than one managed_policy_file directive.'
    }
    if ($matches.Count -eq 1) {
        return $matches[0].Value
    }
    return $null
}

function Set-ApolloDirective([string]$Contents, [string]$Value) {
    $existing = Get-ApolloDirective $Contents
    $directive = 'managed_policy_file = ' + $Value
    if ($null -ne $existing) {
        return [regex]::Replace($Contents, '(?m)^[ \t]*managed_policy_file[ \t]*=.*$', [Text.RegularExpressions.MatchEvaluator]{ param($match) $directive })
    }
    $separator = if ($Contents.EndsWith("`n")) { '' } else { [Environment]::NewLine }
    return $Contents + $separator + $directive + [Environment]::NewLine
}

function Write-ApolloConfigAtomic([string]$Path, [string]$Contents) {
    Assert-NoReparseSegments $Path
    $originalAcl = Get-Acl -LiteralPath $Path
    $directory = [IO.Path]::GetDirectoryName($Path)
    $temporary = Join-Path $directory ('.moonlight-managed-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Assert-NoReparseSegments $temporary
    try {
        [IO.File]::WriteAllText($temporary, $Contents, (New-Object Text.UTF8Encoding($false)))
        Set-Acl -LiteralPath $temporary -AclObject $originalAcl
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Wait-ServiceState([string]$Name, [string]$State, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service.Status.ToString() -eq $State) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Service $Name did not reach state $State within $Seconds seconds."
}

function Wait-ManagedProtocol([int]$Port, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri ("http://127.0.0.1:{0}/serverinfo" -f $Port) -TimeoutSec 2
            [xml]$document = $response.Content
            $node = $document.SelectSingleNode('//ManagedAccessProtocol')
            if ($null -ne $node -and $node.InnerText -eq '1') {
                return
            }
        }
        catch {
            # Apollo may still be starting. Retry until the bounded deadline.
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Apollo did not report ManagedAccessProtocol 1 after restart.'
}

function Get-AgentPolicyReadinessError([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return 'the agent has not written a policy file'
        }
        Assert-NoReparseSegments $Path
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Length -lt 2 -or $item.Length -gt (512 * 1024)) {
            return 'the policy file size is invalid'
        }
        $policy = ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
        $protocolProperty = $policy.PSObject.Properties['protocol']
        $validUntilProperty = $policy.PSObject.Properties['valid_until']
        $leasesProperty = $policy.PSObject.Properties['leases']
        if ($null -eq $protocolProperty -or [int]$protocolProperty.Value -ne 1) {
            return 'the policy protocol is not 1'
        }
        if ($null -eq $validUntilProperty) {
            return 'the policy has no valid_until value'
        }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $validUntil = [long]$validUntilProperty.Value
        if ($validUntil -le $now -or $validUntil -gt ($now + 120)) {
            return 'the policy validity window is outside the allowed readiness range'
        }
        if ($null -eq $leasesProperty -or -not ($leasesProperty.Value -is [Array])) {
            return 'the policy leases value is not an array'
        }
        return $null
    }
    catch {
        return $_.Exception.Message
    }
}

function Wait-AgentPolicyReady([string]$Path, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $lastError = 'the readiness check has not run'
    do {
        $service = Get-Service -Name $agentServiceName -ErrorAction Stop
        if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Running) {
            $lastError = 'the managed host agent service is not running'
        }
        else {
            $lastError = Get-AgentPolicyReadinessError $Path
            if ($null -eq $lastError) {
                return
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Backend readiness failed: the agent did not produce a valid protocol 1 policy within $Seconds seconds ($lastError). Check the backend URL, TLS trust, host token, and machine state."
}

function Remove-AgentServiceIfPresent {
    $service = Get-Service -Name $agentServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return
    }
    if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $agentServiceName -Force
        Wait-ServiceState $agentServiceName 'Stopped' 20
    }
    Set-Service -Name $agentServiceName -StartupType Disabled
    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    & $sc @('delete', $agentServiceName) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to delete the partial managed host agent service; it was left stopped and disabled.'
    }
}

Assert-Administrator

$uri = $null
if (-not [Uri]::TryCreate($BackendUrl, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or
    -not [string]::IsNullOrEmpty($uri.UserInfo) -or
    -not [string]::IsNullOrEmpty($uri.Query) -or
    -not [string]::IsNullOrEmpty($uri.Fragment) -or
    ($uri.AbsolutePath -ne '/' -and $uri.AbsolutePath -ne '')) {
    throw 'BackendUrl must be an HTTPS origin without a path, credentials, query, or fragment.'
}
$normalizedBackendUrl = $uri.GetLeftPart([UriPartial]::Authority)

$AgentExecutable = Get-FullLiteralPath $AgentExecutable $true
$ApolloConfig = Get-FullLiteralPath $ApolloConfig $true
$ServerCertificate = Get-FullLiteralPath $ServerCertificate $true
foreach ($path in @($installRoot, $AgentExecutable, $ApolloConfig, $ServerCertificate, $installedAgent, $agentConfig, $policyFile, $stateFile, $backupFile)) {
    Assert-NoReparseSegments $path
}
if ((Get-Item -LiteralPath $AgentExecutable).PSIsContainer -or (Get-Item -LiteralPath $ApolloConfig).PSIsContainer -or (Get-Item -LiteralPath $ServerCertificate).PSIsContainer) {
    throw 'AgentExecutable, ApolloConfig, and ServerCertificate must be files.'
}

$certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ServerCertificate)
$now = Get-Date
if ($now -lt $certificate.NotBefore -or $now -gt $certificate.NotAfter) {
    throw 'ServerCertificate is not currently valid.'
}

$apolloSid = Resolve-AccountSid $ApolloReadAccount
Assert-SupportedApolloAccount $apolloSid
$apolloService = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ApolloServiceName.Replace("'", "''"))
if ($null -eq $apolloService) {
    throw "Apollo service was not found: $ApolloServiceName"
}
$actualApolloSid = Resolve-AccountSid $apolloService.StartName
if ($actualApolloSid.Value -ne $apolloSid.Value) {
    throw "ApolloReadAccount does not match the account running $ApolloServiceName."
}
if ($null -ne (Get-Service -Name $agentServiceName -ErrorAction SilentlyContinue)) {
    throw "$agentServiceName is already installed. Disable or remove the existing installation before reinstalling."
}

$agentServiceCreated = $false
$backupCreated = $false
$apolloStopAttempted = $false
$apolloStopSucceeded = $false
$apolloOriginallyRunning = (Get-Service -Name $ApolloServiceName).Status -eq [ServiceProcess.ServiceControllerStatus]::Running
$originalApolloConfig = [IO.File]::ReadAllText($ApolloConfig)
$originalDirective = Get-ApolloDirective $originalApolloConfig

try {
    Assert-UnderInstallRoot $binDirectory
    if (-not (Test-Path -LiteralPath $installRoot)) {
        [void](New-Item -ItemType Directory -Path $installRoot)
    }
    Assert-NoReparseSegments $installRoot
    Set-PrivateDirectoryAcl $installRoot $apolloSid $true

    foreach ($directory in @($binDirectory, $privateDirectory, $policyDirectory, $backupDirectory)) {
        Assert-UnderInstallRoot $directory
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory)
        }
        Assert-NoReparseSegments $directory
    }
    Set-PrivateDirectoryAcl $binDirectory $apolloSid $false
    Set-PrivateDirectoryAcl $privateDirectory $apolloSid $false
    Set-PrivateDirectoryAcl $backupDirectory $apolloSid $false
    Set-PolicyDirectoryAcl $policyDirectory $apolloSid

    $sourceHash = (Get-FileHash -LiteralPath $AgentExecutable -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $AgentExecutable -Destination $installedAgent -Force
    Set-PrivateFileAcl $installedAgent
    $installedHash = (Get-FileHash -LiteralPath $installedAgent -Algorithm SHA256).Hash
    if ($sourceHash -ne $installedHash) {
        throw 'Installed agent executable did not match the source SHA-256 hash.'
    }

    Copy-Item -LiteralPath $ApolloConfig -Destination $backupFile -Force
    Set-PrivateFileAcl $backupFile
    $backupCreated = $true

    $bstr = [IntPtr]::Zero
    $plainToken = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($HostToken)
        $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ($plainToken -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'HostToken must contain exactly 64 hexadecimal characters.'
        }
        $configuration = [ordered]@{
            backend_url = $normalizedBackendUrl
            host_token = $plainToken.ToLowerInvariant()
            policy_file = $policyFile
            server_certificate_file = $ServerCertificate
            http_port = $HttpPort
        }
        Write-Utf8FileAtomic $agentConfig (($configuration | ConvertTo-Json -Depth 2) + [Environment]::NewLine)
        $configuration['host_token'] = $null
    }
    finally {
        $plainToken = $null
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    $state = [ordered]@{
        protocol = 1
        apollo_config = $ApolloConfig
        apollo_service = $ApolloServiceName
        policy_file = $policyFile
        original_directive = $originalDirective
        installed_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-Utf8FileAtomic $stateFile (($state | ConvertTo-Json -Depth 2) + [Environment]::NewLine)

    $apolloStopAttempted = $true
    if ((Get-Service -Name $ApolloServiceName).Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $ApolloServiceName -Force
    }
    Wait-ServiceState $ApolloServiceName 'Stopped' 20
    $apolloStopSucceeded = $true
    $updatedApolloConfig = Set-ApolloDirective $originalApolloConfig $policyFile
    Write-ApolloConfigAtomic $ApolloConfig $updatedApolloConfig

    Start-Service -Name $ApolloServiceName
    Wait-ServiceState $ApolloServiceName 'Running' 30
    Wait-ManagedProtocol $HttpPort 30

    if ($installedAgent.Contains('"') -or $agentConfig.Contains('"')) {
        throw 'Installer paths containing quote characters are not supported.'
    }
    if (Test-Path -LiteralPath $policyFile) {
        Assert-NoReparseSegments $policyFile
        Remove-Item -LiteralPath $policyFile -Force
    }
    $binaryPath = '"' + $installedAgent + '" -config "' + $agentConfig + '"'
    New-Service -Name $agentServiceName -BinaryPathName $binaryPath -DisplayName 'Moonlight Managed Host Agent' -StartupType Automatic | Out-Null
    $agentServiceCreated = $true

    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    & $sc @('failure', $agentServiceName, 'reset=', '86400', 'actions=', 'restart/5000/restart/15000/restart/60000') | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to configure agent service recovery actions.'
    }
    & $sc @('failureflag', $agentServiceName, '1') | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enable agent service recovery actions.'
    }

    Start-Service -Name $agentServiceName
    Wait-ServiceState $agentServiceName 'Running' 15
    Wait-AgentPolicyReady $policyFile 30

    Write-Host 'Managed host agent installed. Apollo reports ManagedAccessProtocol 1 and the backend delivered a valid initial policy.'
}
catch {
    $failure = $_
    $rollbackFailure = $null
    if ($agentServiceCreated) {
        try {
            Remove-AgentServiceIfPresent
        }
        catch {
            $rollbackFailure = $_.Exception.Message
            Stop-Service -Name $agentServiceName -Force -ErrorAction SilentlyContinue
            Set-Service -Name $agentServiceName -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }
    if ($apolloStopAttempted) {
        if (-not $apolloStopSucceeded) {
            Write-Verbose 'Apollo stop did not report success; rollback will still force a stopped state before restoring the backup.'
        }
        try {
            if (-not $backupCreated) {
                throw 'the protected Apollo configuration backup is unavailable'
            }
            if ((Get-Service -Name $ApolloServiceName).Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
                Stop-Service -Name $ApolloServiceName -Force
                Wait-ServiceState $ApolloServiceName 'Stopped' 20
            }
            $backupContents = [IO.File]::ReadAllText($backupFile)
            Write-ApolloConfigAtomic $ApolloConfig $backupContents
            if ($apolloOriginallyRunning) {
                Start-Service -Name $ApolloServiceName
                Wait-ServiceState $ApolloServiceName 'Running' 30
            }
        }
        catch {
            $apolloRollbackFailure = $_.Exception.Message
            if ($null -eq $rollbackFailure) {
                $rollbackFailure = $apolloRollbackFailure
            }
            else {
                $rollbackFailure += '; ' + $apolloRollbackFailure
            }
            Stop-Service -Name $ApolloServiceName -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($cleanupPath in @($policyFile, $agentConfig, $stateFile)) {
        try {
            if (Test-Path -LiteralPath $cleanupPath) {
                Assert-NoReparseSegments $cleanupPath
                Remove-Item -LiteralPath $cleanupPath -Force
            }
        }
        catch {
            $cleanupFailure = "unable to remove $cleanupPath`: $($_.Exception.Message)"
            if ($null -eq $rollbackFailure) {
                $rollbackFailure = $cleanupFailure
            }
            else {
                $rollbackFailure += '; ' + $cleanupFailure
            }
        }
    }
    if ($null -ne $rollbackFailure) {
        Stop-Service -Name $agentServiceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $agentServiceName -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name $ApolloServiceName -Force -ErrorAction SilentlyContinue
        throw "Installation failed: $($failure.Exception.Message) Rollback also failed: $rollbackFailure Apollo and the managed agent were left stopped; policy removal was attempted."
    }
    throw $failure
}
