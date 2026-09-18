# AV1 HDR black screens in VideoToolbox: cause and iOS integration

This document is for **moonlight-ios** and other Apple-platform clients that decode with VideoToolbox. The Moonlight Qt fix is in [upstream PR #168](https://github.com/qiin2333/moonlight-qt/pull/168), implemented in `app/streaming/video/av1obu.{h,cpp}`. The observations and validation results below are from that upstream investigation.

## Overview

In the observed **AV1 HDR** path, NVENC splits a frame into `OBU_FRAME_HEADER(3)` and `OBU_TILE_GROUP(4)`. Its SDR path emits a combined `OBU_FRAME(6)`. VideoToolbox rejects the split form, returning `kVTVideoDecoderMalfunctionErr (-12911)` for every frame and producing a black screen.

The fix combines the two OBUs into one `OBU_FRAME` **before submitting the temporal unit to VideoToolbox**. It moves bytes without parsing entropy-coded data; the only bit-level operation clears a stop bit. A complete standalone C implementation is included below.

The trigger is the encoder's OBU packaging, not HDR10+ metadata. The observed NVENC AV1 HDR stream uses the split form; AMF and NVENC AV1 SDR use the combined form. Any encoder emitting the same split layout can encounter this decoder limitation, so the workaround should follow the bitstream layout rather than an encoder-name check.

## Symptoms

Typical macOS logs are shown below. iOS log text can differ, but the decoder error code is the same.

```text
vt decoder cb: output image buffer is null: -12911
HW accel end frame fail.
avcodec_send_packet() failed
```

`-12911` is `kVTVideoDecoderMalfunctionErr`. In this failure, **every frame fails**; it is not intermittent corruption or packet loss. A client that responds by restarting the decoder and requesting an IDR can loop indefinitely, showing a black screen with occasional flashes.

HEVC, including HEVC HDR and HDR10+, worked on the same host. That comparison helps distinguish this AV1 packaging problem from a general HDR or host failure.

## Root cause

The upstream investigation compared the first-frame OBU sequences using the same M4 client and NVENC host, with an AMF host as another reference:

| Stream | First-frame OBU sequence | Observed result |
|---|---|---|
| NVENC AV1 8-bit SDR | `TD(2), SeqHdr(1), FRAME(6)` | Worked for hours. |
| NVENC AV1 10-bit HDR | `TD(2), SeqHdr(1), FRAME_HEADER(3), TILE_GROUP(4)` | Every frame failed with `-12911`. |
| AMF AV1 10-bit HDR | `TD(2), SeqHdr(1), METADATA(5), FRAME(6)` | Worked. |
| NVENC HEVC HDR10+ | Not applicable | Worked. |

The relevant distinction was whether the frame header and tile group were combined into `OBU_FRAME`. Resolution, tile count, bitrate, and packet loss were ruled out in that investigation: both 4K and 1080p reproduced the problem, including with 0% packet loss.

AV1 specification section 5.10, `frame_obu()`, defines `OBU_FRAME` as an equivalent packaging of the frame header and tile group. Both forms are valid. The observed VideoToolbox decoder accepted only the combined form in this case.

### Other suspected causes

**HDR10+ metadata:** Initially, a metadata OBU between the frame header and tile group appeared to violate the HDR10+ AV1 Metadata Handling Specification's ordering requirement. However, the first IDR in the 1080p session contained no metadata at all: its sequence was `2,1,3,4`, and it still failed with `-12911`. Neither metadata presence nor placement was necessary to trigger the failure.

**FFmpeg:** For clients using FFmpeg's VideoToolbox hardware acceleration, `videotoolbox_av1.c` passes the complete OBU range from `start_unit` through `nb_unit` in `end_frame`. In `av1dec.c`, `s->nb_unit = i + 1`, where `i` is the tile-group index, includes that tile group. No OBU was omitted. An iOS client building `CMBlockBuffer` and feeding `VTDecompressionSession` directly can encounter the same issue when passing the original bytes through.

**Encoder configuration:** The inspected `NV_ENC_CONFIG_AV1` and `NV_ENC_PIC_PARAMS_AV1` structures in `nvEncodeAPI.h` provided no control such as `enableFrameOBU` for selecting this packaging. The driver chooses it. A client-side adaptation can therefore support hosts that cannot be modified, including existing Sunshine versions, older drivers, and hosted services.

### Historical context

foundation-sunshine added AV1 static HDR metadata through `pMasteringDisplay` and `pMaxCll` in commit `a3bd8799`, PR #389, on December 26, 2025. The upstream author suspected that AV1 HDR on affected macOS/iOS clients might have failed since then rather than being a recent regression. That timing was an inference, not a demonstrated first-failure date; older issues with the same symptoms need their own confirmation.

## Repacking the temporal unit

Before passing a temporal unit to VideoToolbox, combine `FRAME_HEADER + TILE_GROUP` into one `OBU_FRAME` in place. Move any intervening metadata OBUs before the combined frame.

### 1. Convert trailing bits correctly

The payload of `OBU_FRAME_HEADER` ends with `trailing_bits(obu_size * 8 - payloadBits)`: a single `1` stop bit followed by zero padding to the end declared by `obu_size`. Because that bound comes from `obu_size`, legal padding can span complete bytes. The final payload byte can therefore be `0x00`.

Inside `OBU_FRAME`, `frame_header_obu()` is followed instead by `byte_alignment()`:

```c
byte_alignment() {
    while ( get_position( ) & 7 )
        zero_bit
}
```

This pads only to the next byte boundary and never adds a full extra byte. Repacking must therefore:

1. Clear the lowest set bit in the last nonzero byte: `lastByte &= lastByte - 1`, for example `0x88` becomes `0x80`.
2. Remove every complete zero byte after that byte. Retaining them would insert padding into the tile-group payload and corrupt the frame.
3. If the byte's **original value is exactly `0x80`**, remove that entire byte too.

The third case occurs when the frame-header payload ends on a byte boundary. `trailing_bits()` then adds a whole `0x80` byte, whereas `byte_alignment()` adds nothing. Keeping it as `0x00` has the same effect as retaining the extra padding bytes. A byte-aligned header is not an exceptional case; the upstream discussion used roughly one in eight possible bit alignments to illustrate why this branch matters.

Test the original value against `0x80`, **not whether clearing the stop bit produces zero**. For example, `0x20` also becomes `0x00`, but its upper two zero bits are actual payload. The remaining six bits become alignment padding, so that byte must remain. Removing it would shift the entire tile group one byte too early. Only an original `0x80` has its stop bit in the first position and contains no payload bits.

Clearing the stop bit alone is insufficient. If the payload is entirely zero, or consists only of a stop bit, reject the rewrite and leave the invalid stream unchanged.

### 2. The output never grows

- Original overhead: two OBU headers plus `leb128(fh)` and `leb128(tg)` length fields.
- Combined overhead: one OBU header plus `leb128(fh + tg)`.

The combined length field needs no more bytes than the two original fields together. Removing a header and any trailing padding therefore never increases the buffer length. The implementation can rewrite in place without allocating an output buffer. It moves data from back to front, tile group before frame header, so no `memmove` overwrites bytes that a later move still needs to read.

When subtracting an OBU's length field from its header size, use the **actual encoded length-field size**, not a canonical size recomputed from the payload length. AV1 permits nonminimal LEB128 encodings: payload length 1 may be encoded as `81 00`. Subtracting only the canonical one-byte size would leave a stray byte between the new header and payload and misalign the temporal unit. Record the number of length bytes consumed during parsing.

Metadata requires temporary storage because it moves earlier while the frame-header payload moves later. The implementation uses a 512-byte stack buffer; typical HDR10+ T.35, mastering-display, and MaxCLL payloads are well under 100 bytes. The bound includes **all headers and payloads of metadata OBUs being moved**. Totals of 512 bytes or less are accepted; 513 bytes or more return the untouched input before any copy occurs.

### 3. Match conservatively

Rewrite only a temporal unit containing exactly one frame header followed by exactly one tile group at the end of the unit, with only metadata between them. Leave the input completely unchanged when it contains:

- An existing `OBU_FRAME`, as in the observed AMF and NVENC SDR streams.
- Multiple tile groups or multiple frames.
- An OBU with `obu_has_size_field == 0`, preventing safe length parsing.
- A frame-header payload containing only zero bytes or only a stop bit.
- More than 512 bytes of metadata to move.
- Different `obu_extension_flag` values on the frame header and tile group, or different extension bytes containing `temporal_id` and `spatial_id`. The combined frame inherits the frame-header header, so combining mismatched extensions could move the tile group into another temporal or spatial layer.

The decision depends on layout, not encoder identity. Any encoder emitting the supported split layout can use this adaptation. Streams already containing `OBU_FRAME` return unchanged. Non-AV1 and non-VideoToolbox paths should not call the function.

### Complete standalone C implementation

The implementation needs only `<stdint.h>` and `<string.h>` and has no FFmpeg or other library dependency. Its `extern "C"` guards allow use from Objective-C, Objective-C++, and C++ projects.


**`av1obu.h`**

```c
#ifndef AV1OBU_H
#define AV1OBU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Repacks an AV1 temporal unit in place, merging an OBU_FRAME_HEADER and its
// OBU_TILE_GROUP into a single OBU_FRAME and hoisting any OBU_METADATA that sat
// between them ahead of the merged frame.
//
// macOS VideoToolbox rejects the split frame header + tile group layout that
// NVENC emits for AV1 HDR, failing every frame with kVTVideoDecoderMalfunctionErr
// (-12911). The same encoder uses the merged OBU_FRAME form for SDR, which decodes
// fine, so rewriting to that form is enough to make HDR decode too.
//
// Hoisting the metadata is a free side effect of the merge, and it happens to be
// what the HDR10+ AV1 Metadata Handling Specification requires: the metadata OBU
// must precede the frame header.
//
// Returns the new length, which is never larger than the original. If the temporal
// unit doesn't match the layout we rewrite, the buffer is left untouched and the
// original length is returned.
int repackAv1TemporalUnit(uint8_t* data, int length);

#ifdef __cplusplus
}
#endif

#endif
```

**`av1obu.c`**

```c
#include "av1obu.h"

#include <string.h>

// OBU types we care about (AV1 spec 6.2.2)
#define OBU_TEMPORAL_DELIMITER 2
#define OBU_FRAME_HEADER       3
#define OBU_TILE_GROUP         4
#define OBU_METADATA           5
#define OBU_FRAME              6

// A temporal unit from a streaming host is a handful of OBUs. Anything longer is
// not the layout we rewrite, so we can bail out rather than grow this.
#define MAX_OBUS 16

// Metadata OBUs that need hoisting are HDR10+ ITU-T T.35, mastering display, and
// content light level payloads - all well under 100 bytes. They have to be stashed
// because they move backwards past the frame header while the frame header's own
// payload moves forwards past them.
#define MAX_HOISTED_METADATA 512

typedef struct {
    int type;
    int headerOffset;   // start of the OBU header
    int headerLength;   // header + leb128 size field
    int sizeBytes;      // length of the leb128 size field as actually encoded
    int payloadOffset;
    int payloadLength;
} Obu;

static int leb128Size(uint64_t value)
{
    int size = 0;
    do {
        size++;
        value >>= 7;
    } while (value != 0);
    return size;
}

static int writeLeb128(uint8_t* out, uint64_t value)
{
    int size = 0;
    do {
        uint8_t byte = value & 0x7F;
        value >>= 7;
        if (value != 0) {
            byte |= 0x80;
        }
        out[size++] = byte;
    } while (value != 0);
    return size;
}

// Parses the temporal unit into obus[]. Returns the OBU count, or -1 if the data
// is malformed or uses a form we can't safely rewrite (missing size fields).
static int parseObus(const uint8_t* data, int length, Obu* obus)
{
    int count = 0;
    int pos = 0;

    while (pos < length) {
        if (count == MAX_OBUS) {
            return -1;
        }

        uint8_t header = data[pos];
        if (header & 0x80) {
            // obu_forbidden_bit must be zero
            return -1;
        }

        int headerLength = 1;
        if (header & 0x04) {
            // obu_extension_flag: one more byte of temporal_id/spatial_id
            headerLength++;
        }
        if (!(header & 0x02)) {
            // No obu_size field, so the OBU runs to the end of the buffer and we
            // can't rewrite anything around it.
            return -1;
        }
        if (pos + headerLength >= length) {
            return -1;
        }

        // leb128 obu_size
        uint64_t size = 0;
        int sizeBytes = 0;
        for (;;) {
            if (sizeBytes == 8 || pos + headerLength + sizeBytes >= length) {
                return -1;
            }
            uint8_t byte = data[pos + headerLength + sizeBytes];
            size |= (uint64_t)(byte & 0x7F) << (7 * sizeBytes);
            sizeBytes++;
            if (!(byte & 0x80)) {
                break;
            }
        }
        headerLength += sizeBytes;

        if (size > (uint64_t)(length - (pos + headerLength))) {
            return -1;
        }

        obus[count].type = (header >> 3) & 0x0F;
        obus[count].headerOffset = pos;
        obus[count].headerLength = headerLength;
        obus[count].sizeBytes = sizeBytes;
        obus[count].payloadOffset = pos + headerLength;
        obus[count].payloadLength = (int)size;
        count++;

        pos += headerLength + (int)size;
    }

    return count;
}

int repackAv1TemporalUnit(uint8_t* data, int length)
{
    Obu obus[MAX_OBUS];
    int count = parseObus(data, length, obus);
    if (count <= 0) {
        return length;
    }

    // Find the split frame we're here to merge. We only handle the exact layout
    // NVENC produces: a single frame header, optional metadata, then a single tile
    // group that ends the temporal unit.
    int frameHeaderIdx = -1;
    int tileGroupIdx = -1;
    for (int i = 0; i < count; i++) {
        switch (obus[i].type) {
        case OBU_FRAME:
            // Already in the merged form the decoder wants
            return length;
        case OBU_FRAME_HEADER:
            if (frameHeaderIdx >= 0) {
                return length;
            }
            frameHeaderIdx = i;
            break;
        case OBU_TILE_GROUP:
            if (tileGroupIdx >= 0) {
                return length;
            }
            tileGroupIdx = i;
            break;
        default:
            break;
        }
    }

    if (frameHeaderIdx < 0 || tileGroupIdx != count - 1 || tileGroupIdx < frameHeaderIdx) {
        return length;
    }

    // Everything between the frame header and the tile group gets hoisted ahead of
    // the merged frame. Only metadata belongs there.
    int metadataLength = 0;
    for (int i = frameHeaderIdx + 1; i < tileGroupIdx; i++) {
        if (obus[i].type != OBU_METADATA) {
            return length;
        }
        metadataLength += obus[i].headerLength + obus[i].payloadLength;
    }
    if (metadataLength > MAX_HOISTED_METADATA) {
        return length;
    }

    Obu frameHeader = obus[frameHeaderIdx];
    Obu tileGroup = obus[tileGroupIdx];

    // The merged OBU_FRAME reuses the frame header's OBU header, so the tile group's
    // header has to agree with it. If they disagree we'd silently move the tile group
    // into a different temporal/spatial layer, so leave the whole thing alone.
    uint8_t fhHeader = data[frameHeader.headerOffset];
    uint8_t tgHeader = data[tileGroup.headerOffset];
    if ((fhHeader & 0x04) != (tgHeader & 0x04)) {
        return length;
    }
    if ((fhHeader & 0x04) &&
        data[frameHeader.headerOffset + 1] != data[tileGroup.headerOffset + 1]) {
        return length;
    }

    // An OBU_FRAME_HEADER payload ends with trailing_bits(obu_size * 8 - payloadBits):
    // a one bit, then zeroes all the way to the end of obu_size. An encoder that
    // over-declares obu_size therefore leaves whole zero bytes at the end, which is
    // legal.
    //
    // Inside an OBU_FRAME the frame header is followed by byte_alignment() instead,
    // and that only pads to the next byte boundary - it can never span a whole byte.
    // So two things have to happen here: the stop bit (the lowest set bit of the last
    // non-zero byte) goes away, and any whole zero bytes after it get dropped.
    // Keeping them would shift them into tile_group_obu()'s payload and corrupt the
    // frame.
    int frameHeaderLength = frameHeader.payloadLength;
    while (frameHeaderLength > 0 && data[frameHeader.payloadOffset + frameHeaderLength - 1] == 0) {
        frameHeaderLength--;
    }
    if (frameHeaderLength == 0) {
        // Malformed: trailing_bits() always writes a stop bit somewhere.
        return length;
    }
    uint8_t origLastByte = data[frameHeader.payloadOffset + frameHeaderLength - 1];
    uint8_t lastByte = origLastByte & (origLastByte - 1);
    // Exactly 0x80 means the stop bit was the first bit of the byte, i.e.
    // frame_header_obu() ended on the previous byte boundary and this byte carries no
    // payload bits at all. byte_alignment() contributes nothing there, so the byte has
    // to disappear rather than become a zero - same reason as the zero bytes above.
    // Any other single-bit value (0x20, 0x40, ...) still holds real payload bits ahead
    // of the stop bit, so it stays as 0x00 and byte_alignment() pads out the rest.
    int dropLastByte = (origLastByte == 0x80);
    if (dropLastByte) {
        frameHeaderLength--;
        if (frameHeaderLength == 0) {
            return length;
        }
    }

    uint64_t mergedPayloadLength = (uint64_t)frameHeaderLength + tileGroup.payloadLength;
    // Recover the OBU header bytes without its size field. Use the size field's actual
    // encoded width, not leb128Size(): AV1 permits non-minimal leb128, so an encoder may
    // have written e.g. 81 00 for a payload of 1.
    int mergedHeaderLength = (frameHeader.headerLength - frameHeader.sizeBytes) +
                             leb128Size(mergedPayloadLength);

    int preambleLength = frameHeader.headerOffset;

    uint8_t metadata[MAX_HOISTED_METADATA];
    if (metadataLength > 0) {
        memcpy(metadata, data + obus[frameHeaderIdx + 1].headerOffset, metadataLength);
    }

    // Lay out [preamble][metadata][OBU_FRAME header][frame header][tile group].
    // The preamble doesn't move. Everything else is written back to front so no
    // move clobbers bytes a later move still needs to read.
    int mergedHeaderOffset = preambleLength + metadataLength;
    int frameHeaderDest = mergedHeaderOffset + mergedHeaderLength;
    int tileGroupDest = frameHeaderDest + frameHeaderLength;

    memmove(data + tileGroupDest, data + tileGroup.payloadOffset, tileGroup.payloadLength);
    memmove(data + frameHeaderDest, data + frameHeader.payloadOffset, frameHeaderLength);
    if (!dropLastByte) {
        data[frameHeaderDest + frameHeaderLength - 1] = lastByte;
    }

    // Reuse the frame header's OBU header so temporal_id/spatial_id survive, but
    // retype it to OBU_FRAME.
    data[mergedHeaderOffset] = (data[frameHeader.headerOffset] & ~0x78) | (OBU_FRAME << 3);
    int written = 1;
    if (data[mergedHeaderOffset] & 0x04) {
        data[mergedHeaderOffset + 1] = data[frameHeader.headerOffset + 1];
        written++;
    }
    written += writeLeb128(data + mergedHeaderOffset + written, mergedPayloadLength);

    if (metadataLength > 0) {
        memcpy(data + preambleLength, metadata, metadataLength);
    }

    return tileGroupDest + tileGroup.payloadLength;
}
```


The upstream author reported compiling this C implementation with `clang -std=c99 -Wall -Wextra` without warnings and obtaining byte-identical output to the Moonlight Qt C++ implementation using the same test harness.

### Integration point

Call the function after the **entire temporal unit has been assembled into contiguous memory** and before submitting it to VideoToolbox.

For clients using moonlight-common-c, every AV1 decode-unit buffer has type `BUFFER_TYPE_PICDATA`; see `Limelight.h`. Only H.264/HEVC use separate VPS/SPS/PPS buffer types. In `DecoderRendererSubmitDecodeUnit`, concatenate `du->bufferList` by following `next`. The resulting buffer contains the whole temporal unit. Insert this before constructing `CMBlockBuffer`:

```c
if (needsAv1ObuRepack) {
    offset = repackAv1TemporalUnit(buffer, offset);
}
// Use offset as the length when creating CMBlockBuffer / CMSampleBuffer.
```

Moonlight Qt uses this position in `ffmpeg.cpp`'s `submitDecodeUnit()`, immediately after the `writeBuffer()` loop and before assigning `m_Pkt->size = offset`.

Enable the adaptation only for **AV1 with VideoToolbox**. Where VideoToolbox is the only decoder, as in the discussed iOS path, the format check is sufficient:

```c
needsAv1ObuRepack = (videoFormat & VIDEO_FORMAT_MASK_AV1) != 0;
```

Do not further restrict it to HDR. Packaging is the trigger, and streams already containing `OBU_FRAME` return after parsing a few headers without copying data.

### Integration notes

- Leave the sequence header untouched. Repacking changes only the frame header, tile group, and metadata placement, so sequence-header-derived `av1C` and `CMFormatDescription` construction remains unchanged.
- Pass your own writable assembly buffer. The function modifies it in place; do not pass moonlight-common-c's decode-unit storage directly.
- Always use the returned length. Keeping the original `offset` leaves trailing bytes in the submitted packet; the basic example shrinks by two bytes.
- The work is header parsing and byte moves. The upstream investigation reported microsecond-scale work for 4K frames, with no `memmove` at all when the layout does not match.

## Validation

### Unit cases

The upstream harness covered the following cases. Repeat them when porting the implementation:

| Case | Expected result |
|---|---|
| Split frame without metadata | `2,1,3,4` becomes `2,1,6`; length 63 becomes 61; stop-bit byte `0x88` becomes `0x80`. |
| Split frame with metadata | `2,1,3,5,4` becomes `2,1,5,6`; metadata moves earlier without changing its contents. |
| Existing `OBU_FRAME` | Input is byte-for-byte unchanged. |
| AMF layout `2,5,6` | Input is byte-for-byte unchanged. |
| Two tile groups | Input is byte-for-byte unchanged. |
| Tile group without a frame header | Input is byte-for-byte unchanged. |
| Whole zero-byte padding after the frame header | Padding is removed; output exactly matches the same frame without padding. |
| Entirely zero frame-header payload | Input is byte-for-byte unchanged. |
| Metadata total of 512 bytes | Repacking succeeds at the supported boundary. |
| Metadata total of 513 bytes | Input is unchanged; return occurs before copying. |
| Original final frame-header byte is `0x80` | Remove the whole byte rather than replacing it with `0x00`. |
| Original final byte is another single-bit value, such as `0x20` | Retain the byte as `0x00`; its upper bits contain real payload. |
| Nonminimal LEB128 length, such as `81 00` | Output exactly matches the same frame with a minimal length encoding. |
| Mismatched frame-header/tile-group extensions | Input is byte-for-byte unchanged. |
| Combined payload crosses a LEB128 boundary, for example 203 bytes | Encode the length as `cb 01`; total length 208 becomes 206. |
| `obu_extension_flag` set | Combined header is `0x36`; preserve the extension byte and calculate the correct length. |

After every rewrite, parse the OBUs again and check that the total bytes consumed exactly equals the returned length.

### Hardware validation

For a new port, connect to an NVENC host with AV1 and HDR enabled. Check that:

1. Video is visible and no `-12911` decoder errors occur.
2. If OBU logging is available, a split sequence such as `2,1,3,5,4` becomes `2,1,5,6`.
3. HDR10+ metadata is recognized where provided. Hoisting it before the frame header also satisfies the ordering required by the HDR10+ AV1 Metadata Handling Specification.

The upstream Moonlight Qt test used an M4, an NVENC host, and a requested 4K120 AV1 10-bit HDR stream:

```text
Video stream is 3840x2160x120 (format 0x2000)   # AV1 MAIN10, hdrMode=1 in the request
Using AV1 OBU repack for VideoToolbox
[av1] Format videotoolbox_vld chosen by get_format().
[av1] Total OBUs on this packet: 3.   OBU idx:0 type:2 / idx:1 type:1 / idx:2 type:6
Received HDR10+ dynamic metadata from the AV1 bitstream
```

- No occurrences of `-12911`, `output image buffer is null`, `HW accel end frame fail`, or `avcodec_send_packet() failed` were recorded.
- No `type:3` or `type:4` appeared after repacking during that session.
- The HDR10+ message had no `(ignored: ...)` suffix, indicating that the renderer consumed the dynamic metadata.
- Observed rates were 55.0 received, 55.0 decoded, and 54.1 rendered FPS, with 0.00% packet loss and 4.16 ms decode time. These are measured rates, distinct from the requested 120 FPS.

The renderer was Vulkan/libplacebo, but hardware decoding still used `videotoolbox_vld`. Select the workaround according to the **hardware decoder**, not the renderer.

These observations establish that repacking worked for that real stream without an observed regression in that session. They do not show whether the encoder emitted whole zero-byte padding after a frame header: the logs contain only the rewritten sequence. That branch was covered by unit tests comparing padded and unpadded forms of the same frame. When there is no such padding, trimming does not change the behavior.

### Regression checks

Also test these paths, even though they should return unchanged or never call the function:

- AMF AV1 HDR, which already emits `OBU_FRAME` in the observed configuration.
- NVENC AV1 SDR, which also emits `OBU_FRAME` in the observed configuration.
- HEVC, for which `needsAv1ObuRepack` is false.

## Separate observation

In the inspected foundation-sunshine `src/nvenc/common_impl/nvenc_base.cpp`, AV1's `outputMaxCll` and `outputMasteringDisplay` were set unconditionally, including for SDR. The upstream investigation identified this as a possible separate issue. It was unrelated to the black-screen cause and outside the scope of this fix.
