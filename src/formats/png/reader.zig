const std = @import("std");
const png = @import("types.zig");
const imgio = @import("../../io.zig");
const utils = @import("../../utils.zig");
const ImageReader = imgio.ImageReader16;
const mem = std.mem;

pub const ImageParsingError = error{InvalidData} || imgio.ImageReaderError;

pub fn loadHeader(reader: *ImageReader) ImageParsingError!png.HeaderData {
    var sig: [png.MagicHeader.len]u8 = undefined;
    var read = try reader.read(sig[0..]);
    if (read != sig.len or !mem.eql(u8, sig[0..], png.MagicHeader)) return error.InvalidData;

    var chunk = try reader.readStruct(png.ChunkHeader);
    if (!mem.eql(u8, chunk.type[0..], png.HeaderData.ChunkType)) return error.InvalidData;
    if (chunk.length() != @sizeOf(png.HeaderData)) return error.InvalidData;

    var header = (try reader.readStruct(png.HeaderData)).*;
    if (!header.isValid()) return error.InvalidData;
    return header;
}

pub fn loadImage(reader: *ImageReader) ImageParsingError!void {
    var header = try loadHeader(reader);
    _ = header;
}

// ********************* TESTS *********************

const expectError = std.testing.expectError;

const validHeaderBuf = png.MagicHeader ++ "\x00\x00\x00\x0d" ++ png.HeaderData.ChunkType ++
    "\x00\x00\x00\xff\x00\x00\x00\x75\x08\x06\x00\x00\x01";

test "loadHeader_valid" {
    const expectEqual = std.testing.expectEqual;
    var reader = ImageReader.fromMemory(validHeaderBuf[0..]);
    var header = try loadHeader(&reader);
    try expectEqual(@as(u32, 0xff), header.width());
    try expectEqual(@as(u32, 0x75), header.height());
    try expectEqual(png.BitDepth.bits8, header.bitDepth);
    try expectEqual(png.ColorType.RgbaColor, header.colorType);
    try expectEqual(png.CompressionMethod.Deflate, header.compressionMethod);
    try expectEqual(png.FilterMethod.Adaptive, header.filterMethod);
    try expectEqual(png.InterlaceMethod.Adam7, header.interlaceMethod);
}

test "loadHeader_empty" {
    const buf: [0]u8 = undefined;
    var reader = ImageReader.fromMemory(buf[0..]);
    try expectError(error.InvalidData, loadHeader(&reader));
}

test "loadHeader_badSig" {
    const buf = "asdsdasdasdsads";
    var reader = ImageReader.fromMemory(buf[0..]);
    try expectError(error.InvalidData, loadHeader(&reader));
}

test "loadHeader_badChunk" {
    const buf = png.MagicHeader ++ "\x00\x00\x01\x0d" ++ png.HeaderData.ChunkType ++ "asad";
    var reader = ImageReader.fromMemory(buf[0..]);
    try expectError(error.InvalidData, loadHeader(&reader));
}

test "loadHeader_shortHeader" {
    const buf = png.MagicHeader ++ "\x00\x00\x00\x0d" ++ png.HeaderData.ChunkType ++ "asad";
    var reader = ImageReader.fromMemory(buf[0..]);
    try expectError(error.EndOfStream, loadHeader(&reader));
}

test "loadHeader_invalidHeaderData" {
    var buf: [validHeaderBuf.len]u8 = undefined;
    std.mem.copy(u8, buf[0..], validHeaderBuf[0..]);
    var pos = png.MagicHeader.len + @sizeOf(png.ChunkHeader);

    try testHeaderWithInvalidValue(buf[0..], pos, 0xf0); // width highest bit is 1
    pos += 3;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x00); // width is 0
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0xf0); // height highest bit is 1
    pos += 3;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x00); // height is 0

    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x00); // invalid bit depth
    try testHeaderWithInvalidValue(buf[0..], pos, 0x07); // invalid bit depth
    try testHeaderWithInvalidValue(buf[0..], pos, 0x03); // invalid bit depth
    try testHeaderWithInvalidValue(buf[0..], pos, 0x04); // invalid bit depth for rgba color type
    try testHeaderWithInvalidValue(buf[0..], pos, 0x02); // invalid bit depth for rgba color type
    try testHeaderWithInvalidValue(buf[0..], pos, 0x01); // invalid bit depth for rgba color type
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x01); // invalid color type
    try testHeaderWithInvalidValue(buf[0..], pos, 0x05);
    try testHeaderWithInvalidValue(buf[0..], pos, 0x07);
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x01); // invalid compression method
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x01); // invalid filter method
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x02); // invalid interlace method
}

fn testHeaderWithInvalidValue(buf: []u8, pos: usize, val: u8) !void {
    var orig = buf[pos];
    buf[pos] = val;
    var reader = ImageReader.fromMemory(buf[0..]);
    try expectError(error.InvalidData, loadHeader(&reader));
    buf[pos] = orig;
}
