$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Passed = 0
function Assert-Test([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message};$script:Passed++ }
$script:DataRoot = Join-Path (Resolve-Path '.\work').Path ('transfer-test-' + [guid]::NewGuid().ToString('N'))
$script:ManifestRoot = Join-Path $script:DataRoot 'manifests'
$script:LogRoot = Join-Path $script:DataRoot 'logs'
$script:ResultRoot = Join-Path $script:DataRoot 'results'
$script:ProgressRoot = Join-Path $script:DataRoot 'progress'
[void][IO.Directory]::CreateDirectory($script:DataRoot)
. '.\outputs\SafeSync\SafeSync.Cloud.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\outputs\SafeSync\SafeSync.ps1'),[ref]$tokens,[ref]$errors)
$wanted=@('Initialize-DataFolders','Write-AppLog','Get-SafeSyncStatePath','New-SafeSyncState','Get-SafeSyncState','Save-SafeSyncState','Save-SafeSyncCheckpoint')
foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){if($node.Name -in $wanted){Invoke-Expression $node.Extent.Text}}

$state=New-SafeSyncState 'delta-test'
$state.CheckpointActive=$true
$state.PendingPaths=@('a.txt','b.txt','c.txt')
for($i=0;$i -lt 2000;$i++){$state.Entries["file-$i.txt"]=[pscustomobject]@{RelativePath="file-$i.txt";Status='BackedUp';Length=12;RemoteId="id-$i"}}
$state.Entries['a.txt']=[pscustomobject]@{RelativePath='a.txt';Status='Unknown';RemoteId='old-id'}
$state.Entries['b.txt']=[pscustomobject]@{RelativePath='b.txt';Status='Unknown';RemoteId='b-id'}
Save-SafeSyncState $state
$basePath=Get-SafeSyncStatePath $state.JobId
$baseHash=(Get-FileHash $basePath).Hash
$state.Entries['a.txt'].Status='BackedUp';$state.Entries['a.txt'].RemoteId='new-id'
$state.Entries['b.txt'].Status='Failed'
$state.PendingPaths=@('c.txt')
Save-SafeSyncCheckpoint $state @('a.txt','b.txt')
Assert-Test ((Get-FileHash $basePath).Hash -eq $baseHash) 'Saving progress rewrote the entire snapshot.'
$loaded=Get-SafeSyncState $state.JobId
Assert-Test ($loaded.CheckpointActive -and @($loaded.PendingPaths).Count -eq 1 -and $loaded.PendingPaths[0] -eq 'c.txt') 'Restart did not replay completed checkpoint paths.'
Assert-Test ($loaded.Entries['a.txt'].RemoteId -eq 'new-id' -and $loaded.Entries['b.txt'].Status -eq 'Failed') 'Restart lost an uploaded ID or a failed retry.'
$segment=Get-ChildItem "$basePath.checkpoints" -Filter '*.json'|Select-Object -First 1
Assert-Test ($segment.Length -lt (Get-Item $basePath).Length / 50) 'The incremental checkpoint is not substantially smaller than the full snapshot.'
$stale=Join-Path $script:DataRoot 'stale-checkpoint.json'
Copy-Item -LiteralPath $segment.FullName -Destination $stale
Save-SafeSyncState $loaded
$loaded.PendingPaths=@('a.txt','c.txt');Save-SafeSyncState $loaded
Copy-Item -LiteralPath $stale -Destination (Join-Path "$basePath.checkpoints" 'stale.json')
$reloaded=Get-SafeSyncState $state.JobId
Assert-Test (@($reloaded.PendingPaths).Count -eq 2) 'A checkpoint from an older generation removed a newly queued path.'

# A local HTTP endpoint exercises the actual native transport, including binary
# multipart bodies, concurrent requests and resumable status codes. No cloud
# credentials or user backup files are involved.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
public sealed class SafeSyncTransferTestServer : IDisposable {
 private TcpListener listener; private volatile bool stopped; private int active;
 public int MaximumActive; public int Requests; public int RangeQueries; public string LastContentRange;
 public readonly List<byte[]> Bodies = new List<byte[]>();
 public readonly List<string> Headers = new List<string>();
 public string Url;
 public SafeSyncTransferTestServer() {
  listener=new TcpListener(IPAddress.Loopback,0);listener.Start();
  Url="http://127.0.0.1:"+((IPEndPoint)listener.LocalEndpoint).Port;
  Task.Factory.StartNew(delegate { while(!stopped){try{var client=listener.AcceptTcpClient();Task.Factory.StartNew(delegate{Handle(client);});}catch{if(stopped)break;}} });
 }
 private void Handle(TcpClient client) {
  int concurrency=Interlocked.Increment(ref active);
  lock(Bodies){MaximumActive=Math.Max(MaximumActive,concurrency);}
  try{using(client)using(var stream=client.GetStream()){
   stream.ReadTimeout=5000;var raw=new MemoryStream();int b;
   while((b=stream.ReadByte())>=0){raw.WriteByte((byte)b);var a=raw.GetBuffer();int n=(int)raw.Length;if(n>=4&&a[n-4]==13&&a[n-3]==10&&a[n-2]==13&&a[n-1]==10)break;}
   string header=Encoding.ASCII.GetString(raw.ToArray());int length=0;string range="";
   foreach(string line in header.Split(new string[]{"\r\n"},StringSplitOptions.None)){
    if(line.StartsWith("Content-Length:",StringComparison.OrdinalIgnoreCase))length=Int32.Parse(line.Substring(15).Trim());
    if(line.StartsWith("Content-Range:",StringComparison.OrdinalIgnoreCase))range=line.Substring(14).Trim();
   }
   var body=new byte[length];int offset=0,count;while(offset<length&&(count=stream.Read(body,offset,length-offset))>0)offset+=count;
   lock(Bodies){Requests++;Bodies.Add(body);Headers.Add(header);LastContentRange=range;}
   int status=200;string extra="";string json="{\"id\":\"test-upload\",\"size\":\"12\"}";
   if(range.StartsWith("bytes */")){Interlocked.Increment(ref RangeQueries);status=308;extra="Range: bytes=0-3\r\n";json="";}
   if(header.StartsWith("PUT /expired")){status=404;json="";}
   if(header.StartsWith("POST /fail")){status=403;json="{}";}
   Thread.Sleep(300);var bytes=Encoding.UTF8.GetBytes(json);
   var prefix=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" Test\r\nContent-Type: application/json\r\nContent-Length: "+bytes.Length+"\r\nConnection: close\r\n"+extra+"\r\n");
   stream.Write(prefix,0,prefix.Length);stream.Write(bytes,0,bytes.Length);
  }}catch{}finally{Interlocked.Decrement(ref active);}
 }
 public void Dispose(){stopped=true;listener.Stop();}
}
'@
$server=New-Object SafeSyncTransferTestServer
$source=Join-Path $script:DataRoot 'source.bin'
$bytes=[byte[]](0,1,2,3,4,5,255,128,0,10,13,42)
[IO.File]::WriteAllBytes($source,$bytes)
$file=Get-Item $source
$operations=New-Object System.Collections.Generic.List[object]
try {
    foreach($i in 0..1){$op=[SafeSyncGoogleTransfer]::Begin($source,(Join-Path $script:DataRoot "stage-$i.bin"),$file.Length,$file.LastWriteTimeUtc,'{"name":"file.bin","parents":["stage"]}','test-token',($server.Url+'/upload'));$operations.Add($op)}
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    while(@($operations.ToArray()|Where-Object{-not $_.Completed}).Count -gt 0 -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    foreach($op in $operations.ToArray()){
        Assert-Test ($op.Completed -and $null -eq $op.Error -and ($op.Json|ConvertFrom-Json).id -eq 'test-upload') 'The background upload did not return a successful response.'
        Assert-Test ($op.Snapshot.Length -eq $file.Length -and $op.Snapshot.Sha256 -eq [SafeSyncFileIntegrity]::Hash($source,'SHA256')) 'The background upload snapshot was not verified.'
    }
    Assert-Test ($server.MaximumActive -eq 2 -and $server.Requests -eq 2) 'Two small files did not upload concurrently in one request per file.'
    $body=$server.Bodies[0];$text=[Text.Encoding]::UTF8.GetString($body)
    $binaryOffset=$text.IndexOf('Content-Type: application/octet-stream')
    $start=[Array]::IndexOf($body,[byte]0,$binaryOffset)
    $identical=$true;for($i=0;$i -lt $bytes.Length;$i++){if($body[$start+$i] -ne $bytes[$i]){$identical=$false}}
    Assert-Test ($identical -and $text.Contains('"parents":["stage"]')) 'Multipart upload altered binary file content or its staging destination.'
    $session=[SafeSyncGoogleTransfer]::QuerySession(($server.Url+'/session'),12)
    Assert-Test ($session.Offset -eq 4 -and -not $session.Complete) 'Resumable upload did not read the server-confirmed offset.'
    $reply=[SafeSyncGoogleTransfer]::ResumeFile($source,($server.Url+'/session'),$session.Offset)|ConvertFrom-Json
    Assert-Test ($reply.id -eq 'test-upload' -and $server.LastContentRange -eq 'bytes 4-11/12') 'Resumable upload did not continue after already transferred bytes.'
    $resumed=$server.Bodies[$server.Bodies.Count-1]
    Assert-Test ($resumed.Length -eq 8 -and $resumed[0] -eq 4 -and $resumed[7] -eq 42) 'Resumable upload resent the prefix or omitted remaining bytes.'
    $asyncResume=[SafeSyncGoogleTransfer]::BeginResume($source,($server.Url+'/session'),4)
    try {
        $deadline=[datetime]::UtcNow.AddSeconds(15)
        while(-not $asyncResume.Completed -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
        Assert-Test ($asyncResume.Completed -and $null -eq $asyncResume.Error -and $asyncResume.BytesSent -eq 12) 'The asynchronous resumable transfer did not finish or report progress.'
    } finally { $asyncResume.Dispose() }
    $changed=[SafeSyncGoogleTransfer]::Begin($source,(Join-Path $script:DataRoot 'changed.bin'),($file.Length+1),$file.LastWriteTimeUtc,'{}','test-token',($server.Url+'/upload'))
    try {
        $deadline=[datetime]::UtcNow.AddSeconds(15)
        while(-not $changed.Completed -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
        Assert-Test ($changed.Completed -and $null -ne $changed.Error -and -not (Test-Path (Join-Path $script:DataRoot 'changed.bin'))) 'A file changed since scanning was uploaded or left staged.'
    } finally { $changed.Dispose() }
    $cancelled=[SafeSyncGoogleTransfer]::Begin($source,(Join-Path $script:DataRoot 'cancelled.bin'),$file.Length,$file.LastWriteTimeUtc,'{}','test-token',($server.Url+'/upload'))
    $cancelled.Dispose()
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    while(-not $cancelled.Completed -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    Assert-Test ($cancelled.Completed -and -not (Test-Path (Join-Path $script:DataRoot 'cancelled.bin'))) 'Cancellation did not stop the transfer and clean its staging file.'
    $expired=[SafeSyncGoogleTransfer]::QuerySession(($server.Url+'/expired'),12)
    Assert-Test $expired.Expired 'An expired resumable session was not detected.'
    $failed=[SafeSyncGoogleTransfer]::Begin($source,(Join-Path $script:DataRoot 'failed.bin'),$file.Length,$file.LastWriteTimeUtc,'{}','test-token',($server.Url+'/fail'))
    while(-not $failed.Completed){Start-Sleep -Milliseconds 50}
    Assert-Test ($null -ne $failed.Error -and -not (Test-Path (Join-Path $script:DataRoot 'failed.bin'))) 'A failed upload retained an unverified local staging file.'
    $failed.Dispose()
}
finally {foreach($op in $operations.ToArray()){$op.Dispose()};$server.Dispose()}
Assert-Test (-not (Test-Path (Join-Path $script:DataRoot 'stage-0.bin')) -and -not (Test-Path (Join-Path $script:DataRoot 'stage-1.bin'))) 'Completed staging files were not removed on disposal.'
Write-Host "PASS: $script:Passed transfer/checkpoint assertions"
