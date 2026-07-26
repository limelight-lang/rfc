# Run the remaining TLC configurations sequentially, resource-capped.
# Results land in <name>.out plus a one-line verdict in results.txt.
Set-Location $PSScriptRoot
$configs = @("MC_dc2solo", "MC_dc2", "MC_dc5", "MC_dc4", "MC_live", "MC_dc3", "MC_sound")
"run started $(Get-Date -Format s)" | Set-Content results.txt
foreach ($c in $configs) {
  $t0 = Get-Date
  java -Xmx3g -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC `
      -config "$c.cfg" -workers 8 RcWalk.tla > "$c.out" 2>&1
  $code = $LASTEXITCODE
  $dt = [int]((Get-Date) - $t0).TotalSeconds
  $stats = (Select-String -Path "$c.out" -Pattern "states generated" |
            Select-Object -Last 1).Line
  $err = (Select-String -Path "$c.out" -Pattern "Error: .*violated|Temporal properties were violated|No error has been found" |
          Select-Object -First 1).Line
  "$c exit=$code time=${dt}s | $err | $stats" | Add-Content results.txt
}
"run finished $(Get-Date -Format s)" | Add-Content results.txt
