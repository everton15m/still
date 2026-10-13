#!/usr/bin/env python3
"""Destructive only to new private temporary image files. Never accepts a device."""
from pathlib import Path
import hashlib, json, shutil, subprocess, tempfile
root=Path(__file__).resolve().parent.parent
bin=root/'build/driver/bin'; tools=root/'build/test-tools'
def run(args, expected=0):
    p=subprocess.run([str(x) for x in args],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode!=expected: raise AssertionError(f'{Path(str(args[0])).name}: expected {expected}, got {p.returncode}: {p.stderr.decode(errors="replace")}')
    return p.stdout
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='ntfsbridge-images-') as tmp:
    tmp=Path(tmp); clean=tmp/'clean.img'
    with clean.open('wb') as file: file.truncate(128*1024*1024)
    run([tools/'mkntfs','--force','--fast','--label','Disposable',clean])
    before=digest(clean)
    clean_report=json.loads(run([bin/'ntfsbridge-check','--report',clean]))
    assert clean_report['stage']=='passed' and clean_report['code']==0
    assert clean_report['deviceOpened']==1 and clean_report['writeBlocked']==0
    assert digest(clean)==before, 'read-only preflight changed clean image'
    run([bin/'ntfs-3g.probe','--readonly',clean])
    run([bin/'ntfs-3g.probe','--readwrite',clean])
    print('PASS clean image, both upstream probes, read-only preflight unchanged')
    for kind, expected, operation, opened in [(1,14,'device_open',0),(2,14,'device_lock',0),(3,13,'device_read',1)]:
        before=digest(clean)
        report=json.loads(run([tools/f'io-error-{kind}','--report',clean],expected))
        assert report['stage']=='volume_open' and report['ioOperation']==operation, report
        assert report['osError']==(5 if kind==3 else 1) and report['deviceOpened']==opened, report
        assert report['hiberCode']==-1 and report['logValid']==-1 and report['writeBlocked']==0
        assert 'PRIVATE_ARGUMENT' not in json.dumps(report)
        assert digest(clean)==before
        print(f'PASS injected {operation} failure: errno preserved, no hibernation/journal verdict, unchanged image')
    payload=tmp/'payload'; payload.write_text('NTFSBridge · România · 日本語 · 🧪\n',encoding='utf8')
    name='/Verificare-日本語-🧪.txt'
    run([tools/'ntfscp',clean,payload,name])
    assert run([tools/'ntfscat',clean,name])==payload.read_bytes()
    print('PASS actual Unicode file copy and content read through libntfs-3g tools')
    for version, clean_log, expected in [(1,1,0),(1,0,15),(2,1,14),(2,0,14)]:
        journal=tmp/f'journal-{version}-{clean_log}.img'; shutil.copyfile(clean,journal)
        run([tools/'make-journal',journal,str(version),str(clean_log)])
        journal.chmod(0o444)
        before=digest(journal)
        report=json.loads(run([bin/'ntfsbridge-check','--report',journal],expected))
        assert report['logMajor']==version and report['logMinor']==(1 if version==1 else 0), report
        assert report['logValid']==1 and report['logClean']==clean_log, report
        assert report['stage']==('cached_journal' if version==2 else 'passed' if clean_log else 'journal_state'), report
        assert report['journalCode']==expected, report
        assert digest(journal)==before, 'read-only journal report changed image'
        print(f'PASS journal {version}.{1 if version==1 else 0}, clean={clean_log}: code {expected}, distinct report, unchanged read-only image')
        flagged=tmp/f'flagged-journal-{version}-{clean_log}.img'; shutil.copyfile(journal,flagged); flagged.chmod(0o600)
        run([tools/'set-flags',flagged,'0x0080']); flagged.chmod(0o444); before=digest(flagged)
        report=json.loads(run([bin/'ntfsbridge-check','--report',flagged],15))
        assert report['stage']=='volume_flags' and report['volumeFlags']==0x0080, report
        assert report['hiberCode']==0 and report['journalCode']==expected and report['writeBlocked']==0, report
        assert report['logMajor']==version and report['logClean']==clean_log, report
        assert digest(flagged)==before
        print(f'PASS flag 0x0080 plus journal {version}: both read-only checks ran, journal code {expected}, write refusal retained, unchanged image')
    dirty=tmp/'dirty.img'; shutil.copyfile(clean,dirty)
    run([tools/'set-dirty',dirty]); before=digest(dirty)
    dirty_report=json.loads(run([bin/'ntfsbridge-check','--report',dirty],15))
    assert dirty_report['stage']=='volume_flags' and dirty_report['volumeFlags'] & 1
    assert digest(dirty)==before, 'dirty image was changed'
    print('PASS dirty volume refused without changes')
    hibernated=tmp/'hibernated.img'; shutil.copyfile(clean,hibernated)
    hiber=tmp/'hiber'; hiber.write_bytes(b'hibr'+bytes(4092))
    run([tools/'ntfscp',hibernated,hiber,'/hiberfil.sys']); before=digest(hibernated)
    hiber_report=json.loads(run([bin/'ntfsbridge-check','--report',hibernated],14))
    assert hiber_report['stage']=='hiber_file' and hiber_report['hiberCode']==14
    assert digest(hibernated)==before, 'hibernated image was changed'
    print('PASS synthetic hibernation refused without changes')
    extended=tmp/'flagged-hibernated.img'; shutil.copyfile(hibernated,extended)
    run([tools/'set-flags',extended,'0x0080']); before=digest(extended)
    report=json.loads(run([bin/'ntfsbridge-check','--report',extended],15))
    assert report['stage']=='volume_flags' and report['hiberCode']==14 and report['journalCode']==0 and report['writeBlocked']==0, report
    assert digest(extended)==before
    print('PASS flag 0x0080 plus hibernation: both checks reported independently, write refusal retained, unchanged image')
    other=tmp/'other-flags.img'; shutil.copyfile(clean,other)
    run([tools/'set-flags',other,'0x0081']); before=digest(other)
    report=json.loads(run([bin/'ntfsbridge-check','--report',other],15))
    assert report['hiberCode']==-1 and report['journalCode']==-1 and report['writeBlocked']==0, report
    assert digest(other)==before
    print('PASS other nonzero flags retain the original early refusal without additional reads or writes')
    corrupt=tmp/'corrupt.img'; shutil.copyfile(clean,corrupt)
    with corrupt.open('r+b') as file:
        boot=file.read(512)
        sector=int.from_bytes(boot[11:13],'little'); cluster=sector*boot[13]
        mft=int.from_bytes(boot[48:56],'little')*cluster
        file.seek(mft); file.write(b'BAAD')
    before=digest(corrupt)
    corrupt_report=json.loads(run([bin/'ntfsbridge-check','--report',corrupt],13))
    assert corrupt_report['stage']=='volume_open'
    assert digest(corrupt)==before
    print('PASS corrupted MFT refused without changes')
    invalid=tmp/'invalid.img'; invalid.write_bytes(bytes(4*1024*1024)); before=digest(invalid)
    invalid_report=json.loads(run([bin/'ntfsbridge-check','--report',invalid],12))
    assert invalid_report['stage']=='volume_open'
    assert digest(invalid)==before
    print('PASS unsupported filesystem refused without changes')
print('No device attached, mounted, formatted, or modified by this test.')
