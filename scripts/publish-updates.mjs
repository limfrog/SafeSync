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
    notes:chosen.file.startsWith('SafeSync-macOS-') ? 'Horizon Entertainment · macOS Google Drive 파일 이동·이름 변경 시 수정 시각을 보존합니다. 마지막 성공 기록과 정확히 일치하는 기존 사본의 잘못된 날짜로 인한 후속 백업 충돌을 보완합니다. 원격 변경·검증 기록 없음은 기존 보호를 유지합니다. 업데이트 후 연결 검증과 기존 작업 재시도를 실행하세요.' : 'Horizon Entertainment · 설치·시작 화면의 오래된 개발 문구와 배포 자료를 정리했습니다. 기존 작업·계정·백업 기록과 안전 검증, 선택형 상세 로그는 유지합니다. Google Drive 전체 권한 구버전은 제한 권한으로 다시 연결하고 새 관리 폴더로 이전해야 합니다. 이미 제한 권한을 사용하는 작업은 이어 사용할 수 있습니다. 자세한 내용은 홈페이지 Release Notes를 확인하세요.'};
}
const feed={schemaVersion:1,windows:release(/^SafeSync-Setup-(\d+\.\d+\.\d+(?:-preview\.\d+)?)\.exe$/),macOS:release(/^SafeSync-macOS-(\d+\.\d+\.\d+)-universal\.zip$/)};
mkdirSync(resolve(root,'updates'),{recursive:true});
writeFileSync(resolve(root,'updates/latest.json'),JSON.stringify(feed,null,2)+'\n');
console.log(`Update catalog: Windows ${feed.windows?.version ?? '-'}, macOS ${feed.macOS?.version ?? '-'}`);
