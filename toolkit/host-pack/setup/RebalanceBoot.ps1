# Rebalance-only process readiness. This checks board processes, not race performance.
function Test-RebalanceProcessSet([string]$root,[ValidateRange(1,8)][int]$seats,[object[]]$processes) {
    $base=[IO.Path]::GetFullPath($root).TrimEnd('\')
    $main=Join-Path $base 'main\Rebalance\flycast.exe'
    $mainCount=@($processes | Where-Object { $_.ExecutablePath -eq $main }).Count
    $missing=@()
    if($mainCount -lt 2){$missing+='main display pair'}
    foreach($n in 1..$seats){
        $exe=Join-Path $base "sat$n\Rebalance\flycast.exe"
        if(-not @($processes | Where-Object { $_.ExecutablePath -eq $exe }).Count){$missing+="sat$n"}
    }
    return [pscustomobject]@{Ready=($missing.Count -eq 0);MissingBoards=$missing;MainProcesses=$mainCount;ExpectedProcesses=($seats+2)}
}
function Get-RebalanceBootState([string]$root,[ValidateRange(1,8)][int]$seats) {
    $processes=@(Get-CimInstance Win32_Process -Filter "Name='flycast.exe'" -ErrorAction SilentlyContinue)
    return Test-RebalanceProcessSet $root $seats $processes
}
