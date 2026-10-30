param($ServiceGroupId, $RecoveryPlanId, $DrillId, $RhubArmEndpoint)
$global:IgniteFinalTestState.ReadinessArguments = $PSBoundParameters
$global:IgniteFinalTestState.ReadinessInvocations++
$global:IgniteFinalTestState.RequestsBeforeReadiness = $global:IgniteFinalTestState.Requests.Count
if ($global:IgniteFinalTestState.FailReadiness) { throw 'Mock readiness failure' }
