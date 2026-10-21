import {readFileSync,writeFileSync,mkdirSync,existsSync,statSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';

const root=resolve(import.meta.dirname,'..');
const entries=readFileSync(resolve(root,'dist/SHA256SUMS.txt'),'utf8').split(/\r?\n/).filter(Boolean).map(line=>{
  const match=/^([a-f0-9]{64})\s+([^/\\]+)$/.exec(line);
  if(!match)throw new Error('Invalid published checksum entry');
  return {sha256:match[1],file:match[2]};
});
function compare(a,b){
  const parse=value=>{const m=/^(\d+)\.(\d+)\.(\d+)(?:-preview\.(\d+))?$/.exec(value);if(!m)throw new Error('Invalid release version');return m.slice(1).map((v,i)=>i===3 && v===undefined ? Number.MAX_SAFE_INTEGER : Number(v));};
  const left=parse(a.version),right=parse(b.version);
  for(let i=0;i<4;i++)if(left[i]!==right[i])return left[i]-right[i];return 0;
}
function release(pattern){
  const items=entries.map(entry=>{const match=pattern.exec(entry.file);return match ? {...entry,version:match[1]} : null;}).filter(Boolean).sort(compare);
  const chosen=items.at(-1);if(!chosen)return null;
  const path=resolve(root,'dist',chosen.file);
  const tree=existsSync(path) ? null : execFileSync('git',['ls-tree','-l','HEAD','--',`dist/${chosen.file}`],{cwd:root,encoding:'utf8'});
  const size=existsSync(path) ? statSync(path).size : Number(/\bblob\s+[a-f0-9]+\s+(\d+)\t/.exec(tree)?.[1]);
  if(!Number.isSafeInteger(size)||size<=0||size>1024*1024*1024)throw new Error('Release file is missing or too large');
  return {version:chosen.version,url:`https://raw.githubusercontent.com/limfrog/SafeSync/main/dist/${chosen.file}`,sha256:chosen.sha256,size,
    notes:'Horizon Entertainment · SafeSync 새 버전입니다. 작업과 계정 설정을 유지합니다. 자세한 변경 사항은 GitHub의 사용 안내를 확인하세요.'};
}
const feed={schemaVersion:1,windows:release(/^SafeSync-Setup-(\d+\.\d+\.\d+(?:-preview\.\d+)?)\.exe$/),macOS:release(/^SafeSync-macOS-(\d+\.\d+\.\d+)-universal\.zip$/)};
mkdirSync(resolve(root,'updates'),{recursive:true});
writeFileSync(resolve(root,'updates/latest.json'),JSON.stringify(feed,null,2)+'\n');
console.log(`Update catalog: Windows ${feed.windows?.version ?? '-'}, macOS ${feed.macOS?.version ?? '-'}`);
