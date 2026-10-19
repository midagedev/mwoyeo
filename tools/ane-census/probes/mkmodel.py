# Writes a tiny Core ML NeuralNetwork model (conv 3x3 + ReLU, three times; 32 channels, 64x64) as a protobuf by hand: no coremltools.
import struct, sys, random
def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f; n >>= 7
        if n: out.append(b | 0x80)
        else: out.append(b); return bytes(out)
def key(field, wire): return varint(field << 3 | wire)
def vint(field, n): return key(field, 0) + varint(n)
def ld(field, payload): return key(field, 2) + varint(len(payload)) + payload
def s(field, text): return ld(field, text.encode())
def packed_u64(field, vals): return ld(field, b''.join(varint(v) for v in vals))
def floats(field, vals): return ld(field, struct.pack('<%df' % len(vals), *vals))

def feature(name, shape):
    arr = packed_u64(1, shape) + vint(2, 65568)               # ArrayFeatureType: shape, FLOAT32
    return s(1, name) + ld(3, ld(5, arr))                      # FeatureDescription: name, type.multiArrayType
def conv(name, inp, out, ch):
    random.seed(7)
    w = [random.uniform(-0.1, 0.1) for _ in range(ch * ch * 9)]
    p = vint(1, ch) + vint(2, ch) + vint(10, 1) + packed_u64(20, [3, 3]) + packed_u64(30, [1, 1]) + packed_u64(40, [1, 1]) \
        + ld(51, b'') + vint(70, 1) + ld(90, floats(1, w)) + ld(91, floats(1, [0.0] * ch))
    return s(1, name) + s(2, inp) + s(3, out) + ld(100, p)
def relu(name, inp, out):
    return s(1, name) + s(2, inp) + s(3, out) + ld(130, ld(10, b''))   # activation { ReLU = 10 {} }

ch, hw = 32, 64
layers = b''
cur = 'x'
for i in range(3):
    layers += ld(1, conv('conv%d' % i, cur, 'c%d' % i, ch))
    layers += ld(1, relu('relu%d' % i, 'c%d' % i, 'r%d' % i)); cur = 'r%d' % i
layers = layers.replace(b'', b'')
# the last blob must be named y
last = ld(1, conv('convout', cur, 'y', ch))
desc = ld(1, feature('x', [ch, hw, hw])) + ld(10, feature('y', [ch, hw, hw]))
model = vint(1, 1) + ld(2, desc) + ld(500, layers + last)
open(sys.argv[1], 'wb').write(model)
print('wrote', sys.argv[1], len(model), 'bytes')
