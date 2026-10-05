"""Street names from US Census TIGER/Line FEATNAMES files (public domain), in raw/tiger, to data/us_streets.tsv.

    python tiger_streets.py
"""
import collections
import glob
import os
import struct
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))

def dbf_rows(data):
    n = struct.unpack('<I', data[4:8])[0]; hlen, rlen = struct.unpack('<HH', data[8:12])
    fields = []; off = 32
    while data[off] != 0x0D:
        name = data[off:off+11].split(b'\0')[0].decode(); flen = data[off+16]
        fields.append((name, flen)); off += 32
    for i in range(n):
        rec = data[hlen + i*rlen: hlen + (i+1)*rlen]
        if rec[:1] == b'*': continue
        pos = 1; row = {}
        for name, flen in fields:
            row[name] = rec[pos:pos+flen].decode('latin-1').strip(); pos += flen
        yield row

seen = collections.Counter()
for path in sorted(glob.glob(os.path.join(HERE, 'raw', 'tiger', '*.zip'))):
    z = zipfile.ZipFile(path)
    dbf = [n for n in z.namelist() if n.endswith('.dbf')][0]
    for r in dbf_rows(z.read(dbf)):
        if not r.get('MTFCC', '').startswith('S1'): continue
        name = r['NAME']
        if not name or any(ch.isdigit() for ch in name) and not name[0].isdigit(): continue
        key = (r['PREDIRABRV'], r['PRETYPABRV'], name, r['SUFTYPABRV'], r['SUFDIRABRV'])
        seen[key] += 1
with open(os.path.join(HERE, 'data', 'us_streets.tsv'), 'w') as f:
    for (pd, pt, name, st, sd), c in seen.most_common():
        f.write('\t'.join([pd, pt, name, st, sd]) + '\n')
print(len(seen))
