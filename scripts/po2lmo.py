#!/usr/bin/env python3
# Compile a .po file to LuCI's .lmo format without the LuCI build tools.
# Port of po2lmo.c and sfh_hash() from LuCI (modules/luci-base/src),
# Copyright (C) 2009-2012 Jo-Philipp Wich <jow@openwrt.org>, Apache-2.0.
# It produces byte-identical output.
#
# Usage: scripts/po2lmo.py input.po output.lmo

import struct
import sys

M = 0xffffffff


def sc(b):
    return b - 256 if b > 127 else b


def sfh_hash(data):
    n = len(data)
    if n == 0:
        return 0
    h = n
    i = 0
    for _ in range(n >> 2):
        h = (h + (data[i] | data[i + 1] << 8)) & M
        tmp = ((data[i + 2] | data[i + 3] << 8) << 11 ^ h) & M
        h = (h << 16 ^ tmp) & M
        i += 4
        h = (h + (h >> 11)) & M
    rem = n & 3
    if rem == 3:
        h = (h + (data[i] | data[i + 1] << 8)) & M
        h = (h ^ h << 16) & M
        h = (h ^ sc(data[i + 2]) << 18) & M
        h = (h + (h >> 11)) & M
    elif rem == 2:
        h = (h + (data[i] | data[i + 1] << 8)) & M
        h = (h ^ h << 11) & M
        h = (h + (h >> 17)) & M
    elif rem == 1:
        h = (h + sc(data[i])) & M
        h = (h ^ h << 10) & M
        h = (h + (h >> 1)) & M
    h = (h ^ h << 3) & M
    h = (h + (h >> 5)) & M
    h = (h ^ h << 4) & M
    h = (h + (h >> 17)) & M
    h = (h ^ h << 25) & M
    h = (h + (h >> 6)) & M
    return h


# The quoted string of a .po line: \" and \\ are unescaped, other escapes
# (such as \n) are kept as they are, like po2lmo does.
def extract_string(line):
    if line.startswith(b'#'):
        return None
    start = line.find(b'"')
    if start < 0:
        return None
    out = bytearray()
    esc = False
    for c in line[start + 1:]:
        if esc:
            if c in b'"\\':
                out[-1] = c
            else:
                out.append(c)
            esc = False
        elif c == 0x5c:
            out.append(c)
            esc = True
        elif c == 0x22:
            break
        else:
            out.append(c)
    return bytes(out)


def pad(b):
    return b + b'\0' * ((4 - len(b) % 4) % 4)


def new_msg():
    return {'plural_num': 0, 'ctxt': None, 'id': None, 'id_plural': None, 'val': [None] * 10, 'cur': None}


def convert(lines):
    strings = bytearray()
    index = []

    def add(key_id, val_id, value):
        index.append((key_id, val_id, len(strings), len(value)))
        strings.extend(pad(value))

    def print_msg(msg):
        val = msg['val']
        if msg['id'] and val[0]:
            for i in range(msg['plural_num'] + 1):
                if not val[i]:
                    continue
                if msg['ctxt'] and msg['id_plural']:
                    key = msg['ctxt'] + b'\1' + msg['id'] + b'\2' + str(i).encode()
                elif msg['ctxt']:
                    key = msg['ctxt'] + b'\1' + msg['id']
                elif msg['id_plural']:
                    key = msg['id'] + b'\2' + str(i).encode()
                else:
                    key = msg['id']
                key_id = sfh_hash(key)
                if key_id != sfh_hash(val[i]):
                    add(key_id, msg['plural_num'] + 1, val[i])
        elif val[0]:
            # header: only the Plural-Forms field is kept, under key 0
            v, start, esc = val[0], 0, False
            for p in range(len(v)):
                if esc:
                    if v[p] == 0x6e:   # \n ends a field
                        field = v[start:p - 1]
                        if field[:14].lower() == b'plural-forms: ':
                            add(0, 0, field[14:])
                            break
                        start = p + 1
                    esc = False
                elif v[p] == 0x5c:
                    esc = True

    msg = new_msg()
    msg['plural_num'] = -1
    for line in lines + [None]:
        eof = line is None
        if not eof and line.startswith(b'msgctxt "'):
            if msg['id'] or msg['val'][0]:
                print_msg(msg)
                msg = new_msg()
            msg['ctxt'] = None
            msg['cur'] = ('ctxt', None)
        elif eof or line.startswith(b'msgid "'):
            if msg['id'] or msg['val'][0]:
                print_msg(msg)
                msg = new_msg()
            msg['id'] = None
            msg['cur'] = ('id', None)
        elif line.startswith(b'msgid_plural "'):
            msg['id_plural'] = None
            msg['cur'] = ('id_plural', None)
        elif line.startswith(b'msgstr "') or line.startswith(b'msgstr['):
            n = int(line[7:].split(b']')[0]) if line[6:7] == b'[' else 0
            if n >= 10:
                sys.exit('Error: Too many plural forms')
            msg['plural_num'] = n
            msg['val'][n] = None
            msg['cur'] = ('val', n)
        if eof:
            break
        if msg['cur']:
            s = extract_string(line)
            if s:
                field, n = msg['cur']
                if field == 'val':
                    msg['val'][n] = (msg['val'][n] or b'') + s
                else:
                    msg[field] = (msg[field] or b'') + s

    if not strings:
        return None
    out = bytes(strings)
    for e in sorted(index, key=lambda e: e[0]):
        out += struct.pack('>4I', *e)
    return out + struct.pack('>I', len(strings))


def main():
    if len(sys.argv) != 3:
        sys.exit('Usage: %s input.po output.lmo' % sys.argv[0])
    with open(sys.argv[1], 'rb') as f:
        lines = f.read().splitlines(keepends=True)
    out = convert(lines)
    if out is not None:
        with open(sys.argv[2], 'wb') as f:
            f.write(out)


if __name__ == '__main__':
    main()
