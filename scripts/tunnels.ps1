# Opens the two local tunnels into Minikube, each in its own window:
#   App      -> http://127.0.0.1:8080   (nginx, namespace sw-update)
#   Grafana  -> http://127.0.0.1:3000   (namespace monitoring)
# Run it again any time a tunnel window shows an error (e.g. after a deploy replaced the pod).
#
#   powershell -ExecutionPolicy Bypass -File scripts\tunnels.ps1

# Stop any old port-forwards first, so ports 8080/3000 are free.
Get-CimInstance Win32_Process -Filter "Name='kubectl.exe'" |
  Where-Object { $_.CommandLine -match 'port-forward' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

function Open-Tunnel($title, $namespace, $service, $ports) {
  $cmd = "`$host.ui.RawUI.WindowTitle='$title'; kubectl -n $namespace port-forward svc/$service $ports"
  Start-Process powershell -ArgumentList '-NoExit', '-Command', $cmd
}

Open-Tunnel 'APP 8080'     'sw-update'  'sw-nginx' '8080:80'
Open-Tunnel 'GRAFANA 3000' 'monitoring' 'grafana'  '3000:3000'

Start-Sleep -Seconds 4
foreach ($url in 'http://127.0.0.1:8080/healthz', 'http://127.0.0.1:3000/api/health') {
  try   { $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 5; Write-Host "OK   $url -> $($r.StatusCode)" -ForegroundColor Green }
  catch { Write-Host "FAIL $url -> $($_.Exception.Message)" -ForegroundColor Red }
}
