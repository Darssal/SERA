"""Extract one verified SDK emulator GPT/super logical partition, read-only.

Layout follows AOSP system/core/fs_mgr/liblp/include/liblp/metadata_format.h.
The caller must first verify the official SDK ZIP checksum before extraction.
No external Python packages or partition mounting are required.
"""
import argparse
import hashlib
import pathlib
import struct


def exact(source, position, count):
    source.seek(position)
    result = source.read(count)
    if len(result) != count:
        raise ValueError("Truncated image")
    return result


def checked(data, checksum_offset, expected):
    copy = bytearray(data)
    copy[checksum_offset:checksum_offset + 32] = bytes(32)
    if hashlib.sha256(copy).digest() != expected:
        raise ValueError("AOSP LP metadata checksum mismatch")


def extract(image, partition, output):
    if output.exists():
        raise ValueError("Output already exists; choose a new path")
    with image.open("rb") as source:
        gpt = exact(source, 512, 512)
        if gpt[:8] != b"EFI PART":
            raise ValueError("Expected a GPT SDK emulator image")
        table_lba, count, size = struct.unpack_from("<QII", gpt, 72)
        if count > 4096 or size < 128 or size > 4096:
            raise ValueError("Invalid GPT entry table")
        table = exact(source, table_lba * 512, count * size)
        super_offset = None
        for index in range(count):
            entry = table[index * size:(index + 1) * size]
            if entry[:16] == bytes(16):
                continue
            name = entry[56:128].decode("utf-16le").rstrip("\0")
            if name == "super":
                super_offset = struct.unpack_from("<Q", entry, 32)[0] * 512
        if super_offset is None:
            raise ValueError("No super partition")
        geometry = exact(source, super_offset + 4096, 52)
        if struct.unpack_from("<II", geometry) != (0x616C4467, 52):
            raise ValueError("Invalid LP geometry")
        checked(geometry, 8, geometry[8:40])
        header_position = super_offset + 12288
        header_prefix = exact(source, header_position, 128)
        magic, major, minor, header_size = struct.unpack_from("<IHHI", header_prefix)
        if magic != 0x414C5030 or major != 10 or header_size not in (128, 256):
            raise ValueError("Unsupported LP metadata header")
        header = exact(source, header_position, header_size)
        checked(header, 12, header[12:44])
        tables_size = struct.unpack_from("<I", header, 44)[0]
        if tables_size > 8 * 1024 * 1024:
            raise ValueError("Oversized LP metadata tables")
        tables = exact(source, header_position + header_size, tables_size)
        if hashlib.sha256(tables).digest() != header[48:80]:
            raise ValueError("LP table checksum mismatch")
        po, pc, ps = struct.unpack_from("<III", header, 80)
        eo, ec, es = struct.unpack_from("<III", header, 92)
        if ps < 52 or es < 24 or po + pc * ps > tables_size or eo + ec * es > tables_size:
            raise ValueError("Invalid LP table boundaries")
        selected = None
        for index in range(pc):
            position = po + index * ps
            name = tables[position:position + 36].split(b"\0", 1)[0].decode()
            if name == partition:
                _, first, number, _ = struct.unpack_from("<IIII", tables, position + 36)
                selected = (first, number)
        if selected is None or selected[0] + selected[1] > ec:
            raise ValueError("Logical partition not found or invalid extents")
        output.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        total = 0
        with output.open("xb") as destination:
            for index in range(selected[0], sum(selected)):
                sectors, target_type, sector, target_source = struct.unpack_from("<QIQI", tables, eo + index * es)
                remaining = sectors * 512
                if target_source != 0 or target_type not in (0, 1):
                    raise ValueError("Unsupported LP extent source or type")
                source.seek(super_offset + sector * 512)
                while remaining:
                    count = min(remaining, 1024 * 1024)
                    data = source.read(count) if target_type == 0 else bytes(count)
                    if len(data) != count:
                        raise ValueError("Truncated logical extent")
                    destination.write(data)
                    digest.update(data)
                    remaining -= count
                    total += count
        print(f"partition={partition} bytes={total} sha256={digest.hexdigest()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=pathlib.Path)
    parser.add_argument("partition")
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    extract(args.image.resolve(strict=True), args.partition, args.output.resolve())
