Set-StrictMode -Version Latest

function Get-AuthorizationVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$PositiveStatus,
        [Parameter(Mandatory)][int]$NegativeStatus,
        [string]$NegativeCode = '',
        [string[]]$AcceptedCodes = @('CallerNotAllowed')
    )
    if ($PositiveStatus -ne 200) { return 'BLOCKED' }
    if ($NegativeStatus -ge 200 -and $NegativeStatus -lt 300) { return 'FAIL' }
    if ($NegativeStatus -eq 403 -and $NegativeCode -in $AcceptedCodes) { return 'PASS' }
    return 'INCONCLUSIVE'
}

Export-ModuleMember -Function Get-AuthorizationVerdict