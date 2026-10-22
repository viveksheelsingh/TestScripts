param(
    [string]$OperationName,
    [string]$AzureResourceId,
    [string]$FailoverDirection,
    [string]$SourceLocation,
    [string]$PreferredTargetLocations,
    [string]$ResourceIds,
    [string]$Duration,
    [string]$TargetZone,
    [string]$FaultLocation
)

Write-Output 'SIMULATION ONLY: no Azure resource, replication, availability or data has been changed.'
Write-Output ("NoOp operation '{0}' completed at {1:o}." -f $OperationName, [datetime]::UtcNow)
