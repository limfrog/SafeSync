using System.Text.Json;

namespace SafeSync.Core.Cloud;

public sealed partial class GoogleDriveStore : IRemoteDuplicates
{
    public async Task<IReadOnlyList<RemoteItem>> CandidatesAsync(string relative,CancellationToken token)
    {
        relative=RemotePath.Normalize(relative);
        if(rootId.Length==0)throw new InvalidOperationException("Cloud store is not initialized.");
        var root=await Metadata(rootId,token);
        if(root==null || root.Value.True("trashed") || !Parse(root.Value).Folder)throw new CloudBindingException("백업 루트를 확인할 수 없습니다.");
        var current=new List<RemoteItem>{Parse(root.Value)};
        foreach(var part in relative.Split('/',StringSplitOptions.RemoveEmptyEntries))
        {
            var next=new Dictionary<string,RemoteItem>(StringComparer.Ordinal);
            foreach(var parent in current)
            {
                if(!parent.Folder)throw new CloudConflictException(relative,"중복 경로에 일반 파일과 폴더가 섞여 있습니다.");
                foreach(var child in await Children(parent.Id,token))
                    if(child.String("name").Equals(part,StringComparison.OrdinalIgnoreCase)){var item=Parse(child);next[item.Id]=item;}
            }
            if(next.Count>1000)throw new CloudConflictException(relative,"중복 사본이 너무 많습니다. 클라우드에서 폴더를 먼저 정리하세요.");
            current=next.Values.ToList();
        }
        return current;
    }
    public async Task<DuplicatePlan> InspectDuplicatesAsync(string relative,CancellationToken token)
    {
        relative=PathPolicy.Relative(relative);string parent=rootId,path="";RemoteItem? selected=null;var groups=new List<DuplicateGroup>();
        foreach(var part in relative.Split('/'))
        {
            path=path.Length==0 ? part : path+"/"+part;
            var matches=(await Children(parent,token)).Where(c=>c.String("name").Equals(part,StringComparison.OrdinalIgnoreCase)).Select(Parse).OrderBy(c=>c.Id,StringComparer.Ordinal).ToArray();
            if(matches.Length==0)return new(null,groups.ToArray());
            if(matches.Select(i=>i.Folder).Distinct().Count()>1)throw new CloudConflictException(path,"파일·폴더가 섞인 중복 경로입니다. 서로 다른 이름으로 직접 보존한 뒤 다시 비교하세요.");
            if(matches.Length>1)groups.Add(new(path,parent,matches));
            selected=matches[0];parent=selected.Id;
            if(path!=relative && !selected.Folder)throw new CloudConflictException(path,"폴더 경로에 일반 파일이 있습니다.");
        }
        return new(selected,groups.ToArray());
    }
    public async Task PreserveDuplicatesAsync(DuplicatePlan expected,CancellationToken token)
    {
        // Each request is an ID-targeted rename, never deletion. A lost response
        // or crash leaves the old contents intact under either name.
        foreach(var group in expected.Groups)
        {
            var fresh=await InspectDuplicatesAsync(group.Relative,token);
            var current=fresh.Groups.LastOrDefault(g=>g.Relative==group.Relative);
            if(current==null || current.ParentId!=group.ParentId || !RemoteDuplicates.Same(group.Items,current.Items))throw new CloudConflictException(group.Relative,"확인 후 중복 사본이 변경되었습니다. 이름을 바꾸지 않았습니다.");
            foreach(var extra in group.Items.OrderBy(i=>i.Id,StringComparer.Ordinal).Skip(1))
            {
                // Re-resolve the parent before every mutation so moved parents
                // cannot turn a saved ID into authority outside this job root.
                if(await Folder(RemotePath.Parent(group.Relative),false,token)!=group.ParentId)throw new CloudConflictException(group.Relative,"중복 사본의 상위 위치가 변경되었습니다.");
                var metadata=await Metadata(extra.Id,token);
                if(metadata==null || metadata.Value.True("trashed") || Parse(metadata.Value)!=extra || !metadata.Value.GetProperty("parents").EnumerateArray().Any(p=>p.GetString()==group.ParentId))throw new CloudConflictException(group.Relative,"이름 변경 직전 사본이 변경되었습니다.");
                var siblings=await Children(group.ParentId,token);
                string name=extra.Name[..Math.Min(140,extra.Name.Length)]+".SafeSync-conflict-"+Guid.NewGuid().ToString("N");
                if(siblings.Any(c=>c.String("name").Equals(name,StringComparison.OrdinalIgnoreCase)))throw new CloudConflictException(group.Relative,"보관 이름이 이미 존재합니다.");
                var renamed=await http.JsonAsync(HttpMethod.Patch,Api+"files/"+Id(extra.Id)+"?"+CloudJson.Query(("fields",Fields),("supportsAllDrives","true")),new{name},token);
                var actual=Parse(renamed);
                if(actual.Id!=extra.Id || actual.Name!=name || actual.Folder!=extra.Folder || actual.Length!=extra.Length || actual.Hash!=extra.Hash || actual.Sha256!=extra.Sha256)throw new IOException("이름 변경 후 사본 검증에 실패했습니다. 두 위치를 확인하세요.");
            }
        }
    }
}
