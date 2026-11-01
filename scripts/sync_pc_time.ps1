param(
    [string]$Port,
    [ValidateRange(200,60000)][int]$IntervalMs = 1000,
    [switch]$Once,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
function ConvertTo-TimePacket([datetime]$Time) {
    [byte]$hh = ([int][math]::Floor($Time.Hour / 10) * 16) + ($Time.Hour % 10)
    [byte]$mm = ([int][math]::Floor($Time.Minute / 10) * 16) + ($Time.Minute % 10)
    [byte]$ss = ([int][math]::Floor($Time.Second / 10) * 16) + ($Time.Second % 10)
    [byte]$lo = $Time.Millisecond -band 255
    [byte]$hi = $Time.Millisecond -shr 8
    [byte]$check = $hh -bxor $mm -bxor $ss -bxor $lo -bxor $hi
    return [byte[]]@(0xAA, 0x55, $hh, $mm, $ss, $lo, $hi, $check)
}
if ($DryRun) {
    $sampleTime = [datetime]::Now
    [byte[]]$packet = ConvertTo-TimePacket $sampleTime
    Write-Output ('PC time: ' + $sampleTime.ToString('HH:mm:ss.fff'))
    Write-Output ('Packet: ' + [BitConverter]::ToString($packet))
    exit 0
}
if (-not $Port) {
    Write-Output ('Available serial ports: ' + ([System.IO.Ports.SerialPort]::GetPortNames() -join ', '))
    Write-Output 'Specify the board CH340 port, for example: .\sync_pc_time.ps1 -Port COM3'
    exit 1
}
$serial = [System.IO.Ports.SerialPort]::new($Port,115200,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
$serial.DtrEnable = $false
$serial.RtsEnable = $false
$serial.Handshake = [System.IO.Ports.Handshake]::None
$serial.WriteTimeout = 1000
try {
    $serial.Open()
    Write-Output "Sending PC local time to $Port at 115200 8N1; Ctrl+C stops."
    do {
        $pcTime = [datetime]::Now
        [byte[]]$packet = ConvertTo-TimePacket $pcTime
        $serial.Write($packet,0,$packet.Length)
        Write-Output ('Sent ' + $pcTime.ToString('HH:mm:ss.fff'))
        if (-not $Once) { Start-Sleep -Milliseconds $IntervalMs }
    } while (-not $Once)
} finally {
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
