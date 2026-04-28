#Requires -Version 5.1
<#
.SYNOPSIS
    Exports SQL Server instance data from SCOM to a ServiceNow CMDB-compatible JSON file.

.DESCRIPTION
    Connects to a SCOM Management Server using a stored service account credential,
    queries all monitored SQL Server instances, and collects:
      - Instance name & version
      - Host / OS information
      - Databases list
      - Availability Groups
    Output is a JSON file ready to be imported into ServiceNow CMDB
    (target classes: cmdb_ci_db_mssql_instance + cmdb_ci_database).

.PARAMETER SCOMServer
    FQDN or hostname of the SCOM Management Server.

.PARAMETER CredentialName
    The name/label used when the credential was saved with Export-SCOMCredential
    or the Windows Credential Manager target name.

.PARAMETER OutputPath
    Full path for the output JSON file.
    Defaults to .\SCOM_SQL_CMDB_<timestamp>.json in the current directory.

.PARAMETER CredentialFile
    Path to an encrypted credential XML file (created with Export-Clixml).
    Mutually exclusive with -CredentialName.

.EXAMPLE
    .\Export-SCOMSQLToServiceNow.ps1 `
        -SCOMServer "scom.contoso.com" `
        -CredentialFile "C:\Creds\scom_svc.xml" `
        -OutputPath "C:\Export\cmdb_sql.json"

.EXAMPLE
    # First, save credentials once (run interactively as the service account):
    Get-Credential | Export-Clixml -Path "C:\Creds\scom_svc.xml"

    # Then schedule/run the export:
    .\Export-SCOMSQLToServiceNow.ps1 -SCOMServer "scom.contoso.com" `
        -CredentialFile "C:\Creds\scom_svc.xml"

.NOTES
    Requirements:
      - OperationsManager PowerShell module (installed with SCOM Console)
      - Sufficient SCOM read rights for the service account
      - PowerShell 5.1+
    
    ServiceNow target classes produced:
      - cmdb_ci_db_mssql_instance  (one record per SQL instance)
      - cmdb_ci_database            (one record per database, child of instance)
#>

[CmdletBinding(DefaultParameterSetName = 'CredFile')]
param (
    [Parameter(Mandatory)]
    [string] $SCOMServer,

    [Parameter(Mandatory, ParameterSetName = 'CredFile')]
    [ValidateScript({ Test-Path $_ })]
    [string] $CredentialFile,

    [Parameter(Mandatory, ParameterSetName = 'CredMgr')]
    [string] $CredentialName,

    [Parameter()]
    [string] $OutputPath = ".\SCOM_SQL_CMDB_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helpers ──────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        default { 'Cyan'   }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

function Get-StoredCredential {
    <#
    .SYNOPSIS  Returns a PSCredential from an encrypted XML file or Windows Credential Manager.
    #>
    param(
        [string] $FilePath,
        [string] $CredMgrTarget
    )
    if ($FilePath) {
        Write-Log "Loading credential from file: $FilePath"
        return Import-Clixml -Path $FilePath
    }
    # Windows Credential Manager fallback (requires CredentialManager module or cmdkey)
    Write-Log "Loading credential from Windows Credential Manager: $CredMgrTarget"
    try {
        # Attempt via CredentialManager module if available
        if (Get-Module -ListAvailable -Name CredentialManager -ErrorAction SilentlyContinue) {
            Import-Module CredentialManager -ErrorAction Stop
            $cred = Get-StoredCredential -Target $CredMgrTarget -ErrorAction Stop
            return $cred
        }
        throw "CredentialManager module not found. Use -CredentialFile instead."
    }
    catch {
        throw "Could not retrieve credential from Credential Manager. $_"
    }
}

function Get-MonitoringClassSafe {
    <#
    .SYNOPSIS  Returns a SCOM monitoring class, with a clear error if not found.
    #>
    param([string] $ClassName)
    $class = Get-SCOMClass -Name $ClassName -ErrorAction SilentlyContinue
    if (-not $class) {
        Write-Log "SCOM class '$ClassName' not found – skipping." -Level 'WARN'
    }
    return $class
}

function Get-PropertyValue {
    <#
    .SYNOPSIS  Safely reads a named property from a SCOM monitoring object.
    #>
    param($MonitoringObject, [string] $PropertyName)
    try {
        $prop = $MonitoringObject.GetMonitoringProperties() |
                Where-Object { $_.Name -eq $PropertyName } |
                Select-Object -First 1
        if ($prop) {
            return $MonitoringObject[$prop].Value
        }
    } catch { }
    return $null
}

#endregion

#region ── Module check ─────────────────────────────────────────────────────────

Write-Log "Checking for OperationsManager module..."
if (-not (Get-Module -ListAvailable -Name OperationsManager)) {
    throw "OperationsManager module not found. Install the SCOM Operations Console on this machine."
}
Import-Module OperationsManager -ErrorAction Stop
Write-Log "OperationsManager module loaded."

#endregion

#region ── Credential & SCOM connection ─────────────────────────────────────────

$credential = if ($PSCmdlet.ParameterSetName -eq 'CredFile') {
    Get-StoredCredential -FilePath $CredentialFile
} else {
    Get-StoredCredential -CredMgrTarget $CredentialName
}

Write-Log "Connecting to SCOM Management Server: $SCOMServer ..."
try {
    New-SCOMManagementGroupConnection -ComputerName $SCOMServer -Credential $credential -ErrorAction Stop | Out-Null
    Write-Log "Connected successfully."
} catch {
    throw "Failed to connect to SCOM server '$SCOMServer'. Error: $_"
}

#endregion

#region ── SCOM class discovery ─────────────────────────────────────────────────
# Class names vary slightly between SCOM management packs; we try common variants.

Write-Log "Discovering SCOM classes for SQL Server..."

$sqlInstanceClass = Get-MonitoringClassSafe 'Microsoft.SQLServer.DBEngine'
if (-not $sqlInstanceClass) {
    $sqlInstanceClass = Get-MonitoringClassSafe 'Microsoft.SQLServer.2019.DBEngine'
}
if (-not $sqlInstanceClass) {
    # Wildcard fallback – picks the first DB engine class found
    $sqlInstanceClass = Get-SCOMClass | Where-Object { $_.Name -like 'Microsoft.SQLServer*DBEngine*' } |
                        Select-Object -First 1
    if ($sqlInstanceClass) { Write-Log "Using fallback class: $($sqlInstanceClass.Name)" -Level 'WARN' }
}

$sqlDatabaseClass   = Get-MonitoringClassSafe 'Microsoft.SQLServer.Database'
$sqlAGClass         = Get-MonitoringClassSafe 'Microsoft.SQLServer.AvailabilityGroup'
$windowsComputerClass = Get-MonitoringClassSafe 'Microsoft.Windows.Computer'

if (-not $sqlInstanceClass) {
    throw "Could not find any SQL Server DB Engine class in SCOM. Ensure the SQL MP is imported."
}

#endregion

#region ── Data collection ──────────────────────────────────────────────────────

Write-Log "Querying SQL Server instances..."
$sqlInstances = Get-SCOMMonitoringObject -Class $sqlInstanceClass

if (-not $sqlInstances) {
    Write-Log "No SQL Server instances found in SCOM." -Level 'WARN'
}
Write-Log "Found $($sqlInstances.Count) SQL Server instance(s)."

# Pre-load databases and AGs once (faster than per-instance queries)
$allDatabases = if ($sqlDatabaseClass) {
    Write-Log "Loading all SQL databases..."
    Get-SCOMMonitoringObject -Class $sqlDatabaseClass
} else { @() }

$allAGs = if ($sqlAGClass) {
    Write-Log "Loading all Availability Groups..."
    Get-SCOMMonitoringObject -Class $sqlAGClass
} else { @() }

Write-Log "Loaded $($allDatabases.Count) database(s) and $($allAGs.Count) AG(s)."

#endregion

#region ── Build CMDB payload ───────────────────────────────────────────────────

$cmdbRecords  = [System.Collections.Generic.List[object]]::new()
$processedAt  = (Get-Date).ToUniversalTime().ToString('o')  # ISO-8601

foreach ($instance in $sqlInstances) {

    # ── Instance core properties ────────────────────────────────────────────────
    $instanceName    = Get-PropertyValue $instance 'InstanceName'
    $sqlVersion      = Get-PropertyValue $instance 'Version'
    $sqlEdition      = Get-PropertyValue $instance 'Edition'
    $sqlServicePack  = Get-PropertyValue $instance 'ServicePack'
    $tcpPort         = Get-PropertyValue $instance 'TCPPort'
    $sqlCollation    = Get-PropertyValue $instance 'Collation'
    $hostName        = $instance.DisplayName   # Usually "HOSTNAME\INSTANCE" or "HOSTNAME"

    # Resolve to separate host / instance parts
    $parts           = $hostName -split '\\'
    $computerName    = $parts[0].Trim().ToUpper()
    $namedInstance   = if ($parts.Count -gt 1) { $parts[1].Trim() } else { 'MSSQLSERVER' }

    # ── Host / OS info ──────────────────────────────────────────────────────────
    $osName    = $null
    $osVersion = $null
    $osSP      = $null
    $ipAddress = $null

    if ($windowsComputerClass) {
        $hostObj = Get-SCOMMonitoringObject -Class $windowsComputerClass |
                   Where-Object { $_.DisplayName -like "$computerName*" } |
                   Select-Object -First 1

        if ($hostObj) {
            $osName    = Get-PropertyValue $hostObj 'OSVersion'
            $osVersion = Get-PropertyValue $hostObj 'BuildNumber'
            $osSP      = Get-PropertyValue $hostObj 'ServicePackVersion'
            $ipAddress = Get-PropertyValue $hostObj 'IPAddress'
        }
    }

    # ── Databases for this instance ─────────────────────────────────────────────
    # Relationship: database path usually starts with the instance display name
    $instanceDatabases = $allDatabases | Where-Object {
        $_.Path -like "*$hostName*" -or $_.DisplayName -like "*$computerName*"
    }

    $dbList = foreach ($db in $instanceDatabases) {
        $dbName       = Get-PropertyValue $db 'DatabaseName'
        $dbStatus     = Get-PropertyValue $db 'Status'
        $dbRecovery   = Get-PropertyValue $db 'RecoveryModel'
        $dbCompatLevel= Get-PropertyValue $db 'CompatibilityLevel'
        $dbSizeMB     = Get-PropertyValue $db 'DatabaseSizeMB'

        [PSCustomObject]@{
            # ServiceNow cmdb_ci_database fields
            sys_class_name        = 'cmdb_ci_database'
            name                  = if ($dbName) { $dbName } else { $db.DisplayName }
            type                  = 'mssql'
            db_status             = if ($dbStatus) { $dbStatus } else { ($db.HealthState).ToString() }
            recovery_model        = $dbRecovery
            compatibility_level   = $dbCompatLevel
            size_mb               = $dbSizeMB
            scom_id               = $db.Id.ToString()
            scom_path             = $db.Path
            scom_health_state     = ($db.HealthState).ToString()
            scom_last_modified    = $db.LastModified.ToString('o')
        }
    }

    # ── Availability Groups for this instance ───────────────────────────────────
    $instanceAGs = $allAGs | Where-Object {
        $_.Path -like "*$computerName*"
    }

    $agList = foreach ($ag in $instanceAGs) {
        $agName          = Get-PropertyValue $ag 'AvailabilityGroupName'
        $agListener      = Get-PropertyValue $ag 'ListenerDNSName'
        $agSyncHealth    = Get-PropertyValue $ag 'SynchronizationHealth'
        $agPrimaryReplica= Get-PropertyValue $ag 'PrimaryReplicaServerName'

        [PSCustomObject]@{
            name                    = if ($agName) { $agName } else { $ag.DisplayName }
            listener_dns_name       = $agListener
            primary_replica         = $agPrimaryReplica
            synchronization_health  = $agSyncHealth
            scom_id                 = $ag.Id.ToString()
            scom_health_state       = ($ag.HealthState).ToString()
        }
    }

    # ── Assemble instance record ─────────────────────────────────────────────────
    $record = [PSCustomObject]@{

        # ── ServiceNow cmdb_ci_db_mssql_instance fields ──────────────────────
        sys_class_name          = 'cmdb_ci_db_mssql_instance'
        name                    = $hostName
        instance_name           = $namedInstance
        tcp_port                = $tcpPort
        version                 = $sqlVersion
        edition                 = $sqlEdition
        service_pack            = $sqlServicePack
        collation               = $sqlCollation
        correlation_id          = $instance.Id.ToString()   # used for update matching in ServiceNow

        # ── Host / OS ────────────────────────────────────────────────────────
        host_name               = $computerName
        os_name                 = $osName
        os_version              = $osVersion
        os_service_pack         = $osSP
        ip_address              = $ipAddress

        # ── SCOM metadata ────────────────────────────────────────────────────
        scom_id                 = $instance.Id.ToString()
        scom_path               = $instance.Path
        scom_display_name       = $instance.DisplayName
        scom_health_state       = ($instance.HealthState).ToString()
        scom_maintenance_mode   = $instance.InMaintenanceMode.ToString()
        scom_last_modified      = $instance.LastModified.ToString('o')

        # ── Child objects ────────────────────────────────────────────────────
        databases               = @($dbList)
        availability_groups     = @($agList)

        # ── Audit ────────────────────────────────────────────────────────────
        discovery_source        = 'SCOM'
        discovery_timestamp     = $processedAt
        scom_server             = $SCOMServer
    }

    $cmdbRecords.Add($record)
    Write-Log "  Processed: $hostName  |  DBs: $($dbList.Count)  |  AGs: $($agList.Count)"
}

#endregion

#region ── Write JSON output ────────────────────────────────────────────────────

$payload = [PSCustomObject]@{
    metadata = [PSCustomObject]@{
        generated_at     = $processedAt
        scom_server      = $SCOMServer
        total_instances  = $cmdbRecords.Count
        total_databases  = ($cmdbRecords | ForEach-Object { $_.databases.Count } | Measure-Object -Sum).Sum
        total_ags        = ($cmdbRecords | ForEach-Object { $_.availability_groups.Count } | Measure-Object -Sum).Sum
        script_version   = '1.0.0'
    }
    records = $cmdbRecords
}

Write-Log "Writing output to: $OutputPath"
$payload | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8

Write-Log "Done. $($cmdbRecords.Count) instance(s) exported to $OutputPath" -Level 'INFO'

#endregion
