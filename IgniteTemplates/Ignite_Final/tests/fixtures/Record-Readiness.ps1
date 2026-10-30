param($ServiceGroupId, $RecoveryPlanId, $DrillId, $RhubArmEndpoint)
$global:IgniteFinalTestState.ReadinessArguments = $PSBoundParameters
if ($global:IgniteFinalTestState.FailReadiness) { throw 'Mock readiness failure' }
