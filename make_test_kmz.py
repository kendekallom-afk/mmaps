#!/usr/bin/env python3
"""Membuat file KMZ uji untuk memeriksa perilaku package archive.

Hasil (folder ./kmz_cases):
  control_small.kmz        KMZ normal kecil (pembanding)
  big_honest.kmz           KML 150 MB, header JUJUR (harus ditolak oleh cek header)
  big_forged_header.kmz    KML 150 MB, header DIPALSUKAN jadi 1 MB
  big_symlink_entry.kmz    entri 100 MB bertanda symlink Unix (menguji apakah
                           decodeBytes menginflate entri ini lebih awal)
Semua terkompresi menjadi ratusan KB; aman dibuat dan disimpan.
"""
import os, struct, zipfile

OUT = "kmz_cases"
os.makedirs(OUT, exist_ok=True)

HEAD = (b'<?xml version="1.0" encoding="UTF-8"?>'
        b'<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>uji</name>')
TAIL = b'</Document></kml>'
CHUNK = (b'<!-- ' + b'a' * 1019 + b' -->\n') * 1024  # ~1 MB per potongan


def write_big_zip(path, mb, name="doc.kml", symlink=False):
    zi = zipfile.ZipInfo(name)
    zi.compress_type = zipfile.ZIP_DEFLATED
    if symlink:
        zi.create_system = 3                      # Unix
        zi.external_attr = (0o120777 << 16)       # tipe symlink
    with zipfile.ZipFile(path, "w") as z:
        with z.open(zi, "w", force_zip64=False) as f:
            f.write(HEAD)
            for _ in range(mb):
                f.write(CHUNK)
            f.write(TAIL)


def forge_sizes(path, fake_size):
    """Menimpa ukuran tak terkompresi di header lokal dan direktori pusat."""
    data = bytearray(open(path, "rb").read())
    lh = data.find(b"PK\x03\x04")
    ch = data.find(b"PK\x01\x02")
    assert lh == 0 and ch > 0
    struct.pack_into("<I", data, lh + 22, fake_size)   # usize header lokal
    struct.pack_into("<I", data, ch + 24, fake_size)   # usize direktori pusat
    open(path, "wb").write(data)


# 1) kontrol kecil
with zipfile.ZipFile(f"{OUT}/control_small.kmz", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("doc.kml", HEAD + b"<Placemark><name>t</name><Point><coordinates>"
               b"110.0,-7.0,0</coordinates></Point></Placemark>" + TAIL)

# 2) besar tapi jujur
write_big_zip(f"{OUT}/big_honest.kmz", 150)

# 3) besar, header dipalsukan jadi 1 MB
write_big_zip(f"{OUT}/big_forged_header.kmz", 150)
forge_sizes(f"{OUT}/big_forged_header.kmz", 1024 * 1024)

# 4) entri bertanda symlink, 100 MB
write_big_zip(f"{OUT}/big_symlink_entry.kmz", 100, symlink=True)

for fn in sorted(os.listdir(OUT)):
    p = os.path.join(OUT, fn)
    with zipfile.ZipFile(p) as z:
        for i in z.infolist():
            print(f"{fn:26s} file={os.path.getsize(p)//1024:6d} KB | entri={i.filename} "
                  f"deklarasi={i.file_size/1048576:8.2f} MB | "
                  f"dibuat_oleh={i.create_system} atribut={i.external_attr>>16:o}")