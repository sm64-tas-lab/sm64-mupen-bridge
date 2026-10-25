Import-Module "$PSScriptRoot\..\tas\control\SM64Ctl.psm1" -Force -WarningAction SilentlyContinue
[System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::InvariantCulture
$d = (Get-Content "$env:TEMP\sm64sess.txt").Trim()
$s = Connect-Mupen -SessionDir $d
$s.NextId = [int](Get-Random -Minimum 100000 -Maximum 900000)
$s.RespCursor = (Get-Item $s.RespPath).Length
$GOBJ = 0x8033D488; $SZ = 0x260
function U32($v) { $x = [long]$v; if ($x -lt 0) { $x += 4294967296 }; $x }
function Find-Near([double]$X, [double]$Z, [double]$R) {
    $list = @(); for ($i = 0; $i -lt 240; $i++) { $b = $GOBJ + $i * $SZ; $list += @{addr=$b+0x74;type='s16'}; $list += @{addr=$b+0xA0;type='f32'}; $list += @{addr=$b+0xA4;type='f32'}; $list += @{addr=$b+0xA8;type='f32'}; $list += @{addr=$b+0x14C;type='s32'} }
    $v = Read-MemMany -Session $s -List $list
    for ($i = 0; $i -lt 240; $i++) { if ($v[5*$i] -and [math]::Abs($v[5*$i+1]-$X) -lt $R -and [math]::Abs($v[5*$i+3]-$Z) -lt $R) { [pscustomobject]@{ slot=$i; addr=(U32 ($GOBJ+$i*$SZ)); x=[int]$v[5*$i+1]; y=[int]$v[5*$i+2]; z=[int]$v[5*$i+3]; action=$v[5*$i+4] } } }
}
function Get-Chk($a) {
    $v = Read-MemMany -Session $s -List @(@{addr=$a+0xA0;type='f32'},@{addr=$a+0xA4;type='f32'},@{addr=$a+0xA8;type='f32'},@{addr=$a+0xD0;type='s32'},@{addr=$a+0x114;type='s32'},@{addr=$a+0x14C;type='s32'},@{addr=$a+0x154;type='s32'},@{addr=$a+0xC8;type='s32'})
    [pscustomobject]@{ x=$v[0]; y=$v[1]; z=$v[2]; facePitch=$v[3]; angVelPitch=$v[4]; action=$v[5]; timer=$v[6]; moveYaw=$v[7] }
}
function Get-MarioPlat { $mo = U32 (Read-Mem -Session $s -Addr (0x8033B170 + 0x88) -Type u32); U32 (Read-Mem -Session $s -Addr ($mo + 0x214) -Type u32) }
