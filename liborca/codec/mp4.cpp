#include "liborca/codec/mp4.hpp"

#include "liborca/base/logging.hpp"
#include "liborca/codec/aac.hpp"
#include "liborca/codec/alac.hpp"
#include "liborca/storage/iso_bmff.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <string_view>
#include <utility>
#include <vector>

namespace orca::codec {

namespace {

using storage::iso_bmff::Box;
using storage::iso_bmff::Iterator;

[[nodiscard]] auto sample_format_for_bits(std::uint16_t bits) -> SampleFormat {
    if (bits <= 16) {
        return SampleFormat::signed_16;
    }
    if (bits <= 24) {
        return SampleFormat::signed_24;
    }
    return SampleFormat::signed_32;
}

[[nodiscard]] auto checked_add(std::uint64_t first, std::uint64_t second)
    -> expected<std::uint64_t> {
    if (first > std::numeric_limits<std::uint64_t>::max() - second) {
        return fail(ErrorCode::parse, "mp4: time overflow");
    }
    return first + second;
}

[[nodiscard]] auto rescale(std::uint64_t time, std::uint32_t rate, std::uint32_t timescale)
    -> expected<std::uint64_t> {
    if (timescale == 0) {
        return fail(ErrorCode::parse, "mp4: zero timescale");
    }
    const auto scaled = static_cast<unsigned __int128>(time) * rate / timescale;
    if (scaled > std::numeric_limits<std::uint64_t>::max()) {
        return fail(ErrorCode::parse, "mp4: time too long");
    }
    return static_cast<std::uint64_t>(scaled);
}

[[nodiscard]] auto find_box(std::span<const std::byte> bytes, std::string_view kind)
    -> expected<std::optional<Box>> {
    return Iterator::find(bytes, kind);
}

[[nodiscard]] auto unpack_box(std::span<const std::byte> movie, const char* kind)
    -> expected<std::span<const std::byte>> {
    const auto box = find_box(movie, kind);
    if (!box) {
        return std::unexpected(box.error());
    }
    if (!*box) {
        return fail(ErrorCode::parse, "mp4: missing box");
    }
    return (*box)->body;
}

[[nodiscard]] auto full_box_timescale(std::span<const std::byte> body) -> expected<std::uint32_t> {
    if (body.empty()) {
        return fail(ErrorCode::parse, "mp4: empty header box");
    }
    const std::size_t offset = body[0] == std::byte{1} ? 20 : 12;
    const auto timescale = storage::iso_bmff::integer<std::uint32_t>(body, offset);
    if (!timescale || *timescale == 0) {
        return fail(ErrorCode::parse, "mp4: invalid timescale");
    }
    return *timescale;
}

[[nodiscard]] auto movie_timescale(std::span<const std::byte> movie) -> expected<std::uint32_t> {
    const auto header = unpack_box(movie, "mvhd");
    if (!header) {
        return std::unexpected(header.error());
    }
    return full_box_timescale(*header);
}

[[nodiscard]] auto media_timescale(std::span<const std::byte> media) -> expected<std::uint32_t> {
    const auto header = unpack_box(media, "mdhd");
    if (!header) {
        return std::unexpected(header.error());
    }
    return full_box_timescale(*header);
}

[[nodiscard]] auto is_sound(std::span<const std::byte> media) -> expected<bool> {
    const auto handler = find_box(media, "hdlr");
    if (!handler) {
        return std::unexpected(handler.error());
    }
    if (!*handler) {
        return false;
    }
    if ((*handler)->body.size() < 12) {
        return fail(ErrorCode::parse, "mp4: short handler box");
    }
    return std::memcmp((*handler)->body.data() + 8, "soun", 4) == 0;
}

struct Entry {
    Mp4Codec codec;
    std::vector<std::byte> config;
    std::uint16_t channels;
    std::uint32_t sample_rate;
};

using Descriptor = std::span<const std::byte>;

[[nodiscard]] auto descriptor(Descriptor bytes, std::size_t& cursor, std::uint8_t tag)
    -> expected<Descriptor> {
    if (cursor >= bytes.size() || bytes[cursor] != static_cast<std::byte>(tag)) {
        return fail(ErrorCode::parse, "mp4: missing descriptor");
    }
    ++cursor;
    std::size_t length = 0;
    for (int index = 0; index < 4; ++index) {
        if (cursor >= bytes.size()) {
            return fail(ErrorCode::parse, "mp4: truncated descriptor length");
        }
        const auto byte = std::to_integer<unsigned>(bytes[cursor]);
        ++cursor;
        length = (length << 7U) | (byte & 0x7fU);
        if ((byte & 0x80U) == 0U) {
            break;
        }
    }
    if (length > bytes.size() - cursor) {
        return fail(ErrorCode::parse, "mp4: descriptor past end");
    }
    const auto body = bytes.subspan(cursor, length);
    cursor += length;
    return body;
}

[[nodiscard]] auto audio_specific_config(Descriptor esds)
    -> expected<std::optional<std::vector<std::byte>>> {
    if (esds.size() < 4) {
        return fail(ErrorCode::parse, "mp4: short esds");
    }
    std::size_t cursor = 4;
    const auto es = descriptor(esds, cursor, 0x03);
    if (!es) {
        return std::unexpected(es.error());
    }
    std::size_t es_cursor = 3;
    if (es->size() < es_cursor) {
        return fail(ErrorCode::parse, "mp4: short es descriptor");
    }
    const auto flags = std::to_integer<unsigned>((*es)[2]);
    if ((flags & 0x80U) != 0U) {
        es_cursor += 2;
    }
    if ((flags & 0x40U) != 0U) {
        if (es_cursor >= es->size()) {
            return fail(ErrorCode::parse, "mp4: short es URL");
        }
        es_cursor += 1 + std::to_integer<std::size_t>((*es)[es_cursor]);
    }
    if ((flags & 0x20U) != 0U) {
        es_cursor += 2;
    }
    const auto config = descriptor(*es, es_cursor, 0x04);
    if (!config) {
        return std::unexpected(config.error());
    }
    if (config->size() < 13) {
        return fail(ErrorCode::parse, "mp4: short DecoderConfig");
    }
    const auto object_type = std::to_integer<unsigned>((*config)[0]);
    if (object_type != 0x40U && object_type != 0x66U && object_type != 0x67U &&
        object_type != 0x68U) {
        return std::optional<std::vector<std::byte>>{};
    }
    std::size_t config_cursor = 13;
    const auto info = descriptor(*config, config_cursor, 0x05);
    if (!info) {
        return std::unexpected(info.error());
    }
    return std::optional<std::vector<std::byte>>(std::in_place, info->begin(), info->end());
}

struct SampleEntryFields {
    std::span<const std::byte> children;
    std::uint16_t channels = 0;
    std::uint32_t sample_rate = 0;
};

[[nodiscard]] auto sample_entry_fields(std::span<const std::byte> body)
    -> expected<SampleEntryFields> {
    const auto version = storage::iso_bmff::integer<std::uint16_t>(body, 8);
    if (!version) {
        return std::unexpected(version.error());
    }
    std::size_t children_offset = 0;
    switch (*version) {
    case 0:
        children_offset = 28;
        break;
    case 1:
        children_offset = 44;
        break;
    case 2:
        children_offset = 64;
        break;
    default:
        return fail(ErrorCode::parse, "mp4: unknown sample entry version");
    }
    if (body.size() < children_offset) {
        return fail(ErrorCode::parse, "mp4: short sample entry");
    }
    const auto channels = storage::iso_bmff::integer<std::uint16_t>(body, 16);
    const auto rate = storage::iso_bmff::integer<std::uint32_t>(body, 24);
    if (!channels || !rate) {
        return fail(ErrorCode::parse, "mp4: short sample entry");
    }
    return SampleEntryFields{.children = body.subspan(children_offset),
                             .channels = *channels,
                             .sample_rate = *rate >> 16U};
}

[[nodiscard]] auto aac_sample_entry(std::span<const std::byte> children, std::uint16_t channels,
                                    std::uint32_t sample_rate) -> expected<std::optional<Entry>> {
    const auto esds = find_box(children, "esds");
    if (!esds) {
        return std::unexpected(esds.error());
    }
    if (!*esds) {
        return fail(ErrorCode::parse, "mp4: missing esds");
    }
    const auto config = audio_specific_config((*esds)->body);
    if (!config) {
        return std::unexpected(config.error());
    }
    if (!*config) {
        return std::optional<Entry>{};
    }
    return std::optional<Entry>(Entry{.codec = Mp4Codec::aac,
                                      .config = **config,
                                      .channels = channels,
                                      .sample_rate = sample_rate});
}

[[nodiscard]] auto alac_sample_entry(std::span<const std::byte> children)
    -> expected<std::optional<Entry>> {
    const auto cookie = find_box(children, "alac");
    if (!cookie) {
        return std::unexpected(cookie.error());
    }
    if (!*cookie) {
        return fail(ErrorCode::parse, "mp4: missing alac cookie");
    }
    if ((*cookie)->body.size() < 4 + 24) {
        return fail(ErrorCode::parse, "mp4: short alac cookie");
    }
    const auto config = (*cookie)->body.subspan(4, 24);
    const auto sample_rate = storage::iso_bmff::integer<std::uint32_t>(config, 20);
    if (!sample_rate) {
        return std::unexpected(sample_rate.error());
    }
    std::vector<std::byte> copied(config.begin(), config.end());
    return std::optional<Entry>(Entry{.codec = Mp4Codec::alac,
                                      .config = std::move(copied),
                                      .channels = std::to_integer<std::uint8_t>(config[9]),
                                      .sample_rate = *sample_rate});
}

[[nodiscard]] auto sample_entry(std::span<const std::byte> table)
    -> expected<std::optional<Entry>> {
    const auto description = find_box(table, "stsd");
    if (!description) {
        return std::unexpected(description.error());
    }
    if (!*description) {
        return fail(ErrorCode::parse, "mp4: missing sample description");
    }
    if ((*description)->body.size() < 8) {
        return fail(ErrorCode::parse, "mp4: short stsd");
    }
    Iterator entries((*description)->body.subspan(8));
    const auto entry = entries.next();
    if (!entry) {
        return std::unexpected(entry.error());
    }
    if (!*entry) {
        return fail(ErrorCode::parse, "mp4: empty stsd");
    }
    const auto fields = sample_entry_fields((*entry)->body);
    if (!fields) {
        return std::unexpected(fields.error());
    }
    if ((*entry)->is("mp4a")) {
        return aac_sample_entry(fields->children, fields->channels, fields->sample_rate);
    }
    if ((*entry)->is("alac")) {
        return alac_sample_entry(fields->children);
    }
    return std::optional<Entry>{};
}

[[nodiscard]] auto read_time_runs(std::span<const std::byte> table)
    -> expected<std::vector<Mp4TimeRun>> {
    const auto stts = find_box(table, "stts");
    if (!stts) {
        return std::unexpected(stts.error());
    }
    if (!*stts) {
        return fail(ErrorCode::parse, "mp4: missing stts");
    }
    const auto count = storage::iso_bmff::integer<std::uint32_t>((*stts)->body, 4);
    if (!count) {
        return std::unexpected(count.error());
    }
    if (*count > mp4_max_samples ||
        (*stts)->body.size() < 8 + (static_cast<std::size_t>(*count) * 8)) {
        return fail(ErrorCode::parse, "mp4: invalid stts");
    }
    std::vector<Mp4TimeRun> runs(*count);
    for (std::size_t index = 0; index < runs.size(); ++index) {
        const auto run_count =
            storage::iso_bmff::integer<std::uint32_t>((*stts)->body, 8 + (index * 8));
        const auto delta =
            storage::iso_bmff::integer<std::uint32_t>((*stts)->body, 12 + (index * 8));
        if (!run_count || !delta) {
            return fail(ErrorCode::parse, "mp4: truncated stts");
        }
        runs[index] = Mp4TimeRun{.count = *run_count, .delta = *delta};
    }
    return runs;
}

struct SampleSizes {
    std::span<const std::byte> body;
    std::size_t count = 0;
    std::uint32_t uniform = 0;
    std::uint8_t field_bits = 32;

    [[nodiscard]] static auto read(std::span<const std::byte> table) -> expected<SampleSizes> {
        const auto stsz = find_box(table, "stsz");
        if (!stsz) {
            return std::unexpected(stsz.error());
        }
        if (*stsz) {
            const auto uniform = storage::iso_bmff::integer<std::uint32_t>((*stsz)->body, 4);
            const auto count = storage::iso_bmff::integer<std::uint32_t>((*stsz)->body, 8);
            if (!uniform || !count) {
                return fail(ErrorCode::parse, "mp4: truncated stsz");
            }
            if (*uniform == 0 &&
                (*stsz)->body.size() < 12 + (static_cast<std::size_t>(*count) * 4)) {
                return fail(ErrorCode::parse, "mp4: short stsz");
            }
            return SampleSizes{.body = (*stsz)->body.subspan(12),
                               .count = *count,
                               .uniform = *uniform,
                               .field_bits = 32};
        }
        const auto stz2 = find_box(table, "stz2");
        if (!stz2) {
            return std::unexpected(stz2.error());
        }
        if (!*stz2) {
            return fail(ErrorCode::parse, "mp4: missing sample sizes");
        }
        const auto bits = storage::iso_bmff::integer<std::uint32_t>((*stz2)->body, 4);
        const auto count = storage::iso_bmff::integer<std::uint32_t>((*stz2)->body, 8);
        if (!bits || !count) {
            return fail(ErrorCode::parse, "mp4: truncated stz2");
        }
        const auto field_bits = static_cast<std::uint8_t>(*bits & 0xffU);
        if (field_bits != 4 && field_bits != 8 && field_bits != 16) {
            return fail(ErrorCode::parse, "mp4: invalid stz2 width");
        }
        const std::size_t needed = 12 + ((static_cast<std::size_t>(*count) * field_bits + 7) / 8);
        if ((*stz2)->body.size() < needed) {
            return fail(ErrorCode::parse, "mp4: short stz2");
        }
        return SampleSizes{.body = (*stz2)->body.subspan(12),
                           .count = *count,
                           .uniform = 0,
                           .field_bits = field_bits};
    }

    [[nodiscard]] auto at(std::size_t index) const -> expected<std::uint32_t> {
        if (uniform != 0) {
            return uniform;
        }
        switch (field_bits) {
        case 32:
            return storage::iso_bmff::integer<std::uint32_t>(body, index * 4);
        case 16:
            return storage::iso_bmff::integer<std::uint16_t>(body, index * 2);
        case 8:
            return std::to_integer<std::uint8_t>(body[index]);
        default: {
            const auto byte = std::to_integer<std::uint8_t>(body[index / 2]);
            return static_cast<std::uint32_t>(index % 2 == 0 ? byte >> 4U : byte & 0x0fU);
        }
        }
    }
};

struct ChunkOffsets {
    std::span<const std::byte> body;
    std::uint32_t count = 0;
    bool wide = false;

    [[nodiscard]] static auto read(std::span<const std::byte> table) -> expected<ChunkOffsets> {
        const auto stco = find_box(table, "stco");
        if (!stco) {
            return std::unexpected(stco.error());
        }
        if (*stco) {
            const auto count = storage::iso_bmff::integer<std::uint32_t>((*stco)->body, 4);
            if (!count) {
                return fail(ErrorCode::parse, "mp4: truncated stco");
            }
            return ChunkOffsets{.body = (*stco)->body.subspan(8), .count = *count, .wide = false};
        }
        const auto co64 = find_box(table, "co64");
        if (!co64) {
            return std::unexpected(co64.error());
        }
        if (!*co64) {
            return fail(ErrorCode::parse, "mp4: missing chunk offsets");
        }
        const auto count = storage::iso_bmff::integer<std::uint32_t>((*co64)->body, 4);
        if (!count) {
            return fail(ErrorCode::parse, "mp4: truncated co64");
        }
        return ChunkOffsets{.body = (*co64)->body.subspan(8), .count = *count, .wide = true};
    }

    [[nodiscard]] auto at(std::size_t index) const -> expected<std::uint64_t> {
        if (index >= count) {
            return fail(ErrorCode::parse, "mp4: chunk index past end");
        }
        if (wide) {
            return storage::iso_bmff::integer<std::uint64_t>(body, index * 8);
        }
        const auto value = storage::iso_bmff::integer<std::uint32_t>(body, index * 4);
        if (!value) {
            return std::unexpected(value.error());
        }
        return static_cast<std::uint64_t>(*value);
    }
};

[[nodiscard]] auto read_sample_table(std::span<const std::byte> table)
    -> expected<std::vector<Mp4Sample>> {
    const auto sizes = SampleSizes::read(table);
    if (!sizes) {
        return std::unexpected(sizes.error());
    }
    if (sizes->count > mp4_max_samples) {
        return fail(ErrorCode::parse, "mp4: too many samples");
    }
    std::vector<Mp4Sample> samples(sizes->count);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto size = sizes->at(index);
        if (!size) {
            return std::unexpected(size.error());
        }
        samples[index].size = *size;
    }
    return samples;
}

[[nodiscard]] auto apply_chunk_walk(std::span<const std::byte> table,
                                    std::vector<Mp4Sample>& samples) -> expected<void> {
    const auto stsc = find_box(table, "stsc");
    if (!stsc) {
        return std::unexpected(stsc.error());
    }
    if (!*stsc) {
        return fail(ErrorCode::parse, "mp4: missing stsc");
    }
    const auto runs = storage::iso_bmff::integer<std::uint32_t>((*stsc)->body, 4);
    if (!runs) {
        return std::unexpected(runs.error());
    }
    if ((*stsc)->body.size() < 8 + (static_cast<std::size_t>(*runs) * 12)) {
        return fail(ErrorCode::parse, "mp4: short stsc");
    }
    const auto offsets = ChunkOffsets::read(table);
    if (!offsets) {
        return std::unexpected(offsets.error());
    }

    std::size_t sample_index = 0;
    for (std::size_t run = 0; run < *runs; ++run) {
        const auto first_chunk =
            storage::iso_bmff::integer<std::uint32_t>((*stsc)->body, 8 + (run * 12));
        const auto per_chunk =
            storage::iso_bmff::integer<std::uint32_t>((*stsc)->body, 12 + (run * 12));
        if (!first_chunk || !per_chunk) {
            return fail(ErrorCode::parse, "mp4: truncated stsc");
        }
        std::uint64_t next_first = static_cast<std::uint64_t>(offsets->count) + 1;
        if (run + 1 < *runs) {
            const auto next =
                storage::iso_bmff::integer<std::uint32_t>((*stsc)->body, 8 + ((run + 1) * 12));
            if (!next) {
                return fail(ErrorCode::parse, "mp4: truncated stsc");
            }
            next_first = *next;
        }
        if (*first_chunk == 0 || next_first < *first_chunk) {
            return fail(ErrorCode::parse, "mp4: invalid stsc run");
        }
        for (std::uint64_t chunk = *first_chunk; chunk < next_first; ++chunk) {
            auto offset = offsets->at(static_cast<std::size_t>(chunk - 1));
            if (!offset) {
                return std::unexpected(offset.error());
            }
            for (std::uint32_t entry = 0; entry < *per_chunk; ++entry) {
                if (sample_index == samples.size()) {
                    return fail(ErrorCode::parse, "mp4: stsc past sample table");
                }
                samples[sample_index].offset = *offset;
                const auto next_offset = checked_add(*offset, samples[sample_index].size);
                if (!next_offset) {
                    return std::unexpected(next_offset.error());
                }
                *offset = *next_offset;
                ++sample_index;
            }
        }
    }
    if (sample_index != samples.size()) {
        return fail(ErrorCode::parse, "mp4: sample walk mismatch");
    }
    return {};
}

[[nodiscard]] auto read_samples(std::span<const std::byte> table)
    -> expected<std::vector<Mp4Sample>> {
    auto samples = read_sample_table(table);
    if (!samples) {
        return std::unexpected(samples.error());
    }
    const auto applied = apply_chunk_walk(table, *samples);
    if (!applied) {
        return std::unexpected(applied.error());
    }
    return samples;
}

struct Edit {
    std::uint64_t duration = 0;
    std::uint64_t media_time = 0;
};

[[nodiscard]] auto first_presented_edit(std::span<const std::byte> body)
    -> expected<std::optional<Edit>> {
    if (body.size() < 8) {
        return fail(ErrorCode::parse, "mp4: short elst");
    }
    const auto version = std::to_integer<unsigned>(body[0]);
    const auto count = storage::iso_bmff::integer<std::uint32_t>(body, 4);
    if (!count) {
        return std::unexpected(count.error());
    }
    const std::size_t entry_bytes = version == 1 ? 20 : 12;
    for (std::size_t index = 0; index < *count; ++index) {
        const std::size_t at = 8 + (index * entry_bytes);
        std::uint64_t duration = 0;
        std::int64_t media_time = 0;
        if (version == 1) {
            const auto read_duration = storage::iso_bmff::integer<std::uint64_t>(body, at);
            const auto read_media = storage::iso_bmff::integer<std::int64_t>(body, at + 8);
            if (!read_duration || !read_media) {
                return fail(ErrorCode::parse, "mp4: truncated elst");
            }
            duration = *read_duration;
            media_time = *read_media;
        } else {
            const auto read_duration = storage::iso_bmff::integer<std::uint32_t>(body, at);
            const auto read_media = storage::iso_bmff::integer<std::int32_t>(body, at + 4);
            if (!read_duration || !read_media) {
                return fail(ErrorCode::parse, "mp4: truncated elst");
            }
            duration = *read_duration;
            media_time = *read_media;
        }
        if (media_time < 0) {
            continue;
        }
        return std::optional<Edit>(
            Edit{.duration = duration, .media_time = static_cast<std::uint64_t>(media_time)});
    }
    return std::optional<Edit>{};
}

struct GaplessInfo {
    std::uint64_t priming = 0;
    std::uint64_t frames = 0;
};

[[nodiscard]] auto parse_hex(std::string_view text) -> std::optional<std::uint64_t> {
    if (text.empty()) {
        return std::nullopt;
    }
    std::uint64_t value = 0;
    for (const char digit : text) {
        unsigned nibble = 0;
        if (digit >= '0' && digit <= '9') {
            nibble = static_cast<unsigned>(digit - '0');
        } else {
            if (digit >= 'a' && digit <= 'f') {
                nibble = static_cast<unsigned>(digit - 'a' + 10);
            } else {
                if (digit >= 'A' && digit <= 'F') {
                    nibble = static_cast<unsigned>(digit - 'A' + 10);
                } else {
                    return std::nullopt;
                }
            }
        }
        value = (value << 4U) | nibble;
    }
    return value;
}

[[nodiscard]] auto itunes_gapless_info(std::span<const std::byte> movie)
    -> expected<std::optional<GaplessInfo>> {
    const std::array<std::string_view, 2> path{"udta", "meta"};
    const auto list = storage::iso_bmff::descend(movie, path);
    if (!list) {
        return std::unexpected(list.error());
    }
    if (!*list || (*list)->body.size() < 4) {
        return std::optional<GaplessInfo>{};
    }
    const auto items = find_box((*list)->body.subspan(4), "ilst");
    if (!items) {
        return std::unexpected(items.error());
    }
    if (!*items) {
        return std::optional<GaplessInfo>{};
    }
    Iterator boxes((*items)->body);
    while (true) {
        const auto item = boxes.next();
        if (!item) {
            return std::unexpected(item.error());
        }
        if (!*item) {
            break;
        }
        if (!(*item)->is("----")) {
            continue;
        }
        const auto name = find_box((*item)->body, "name");
        if (!name) {
            return std::unexpected(name.error());
        }
        if (!*name || (*name)->body.size() < 4 ||
            std::memcmp((*name)->body.data() + 4, "iTunSMPB", 8) != 0) {
            continue;
        }
        const auto data = find_box((*item)->body, "data");
        if (!data) {
            return std::unexpected(data.error());
        }
        if (!*data || (*data)->body.size() < 8) {
            continue;
        }
        const auto text = std::string_view(reinterpret_cast<const char*>((*data)->body.data() + 8),
                                           (*data)->body.size() - 8);
        std::size_t cursor = 0;
        const auto next_field = [&text, &cursor]() -> std::string_view {
            while (cursor < text.size() && text[cursor] == ' ') {
                ++cursor;
            }
            const std::size_t start = cursor;
            while (cursor < text.size() && text[cursor] != ' ') {
                ++cursor;
            }
            return text.substr(start, cursor - start);
        };
        (void)next_field();
        const auto priming = parse_hex(next_field());
        (void)next_field();
        const auto frames = parse_hex(next_field());
        if (!priming || !frames) {
            return std::optional<GaplessInfo>{};
        }
        return std::optional<GaplessInfo>(GaplessInfo{.priming = *priming, .frames = *frames});
    }
    return std::optional<GaplessInfo>{};
}

[[nodiscard]] auto apply_gapless_bounds(Mp4Track& track, std::span<const std::byte> trak,
                                        std::span<const std::byte> movie,
                                        std::uint32_t movie_timescale_value) -> expected<void> {
    const std::array<std::string_view, 2> path{"edts", "elst"};
    const auto elst = storage::iso_bmff::descend(trak, path);
    if (!elst) {
        return std::unexpected(elst.error());
    }
    if (*elst) {
        const auto edit = first_presented_edit((*elst)->body);
        if (!edit) {
            return std::unexpected(edit.error());
        }
        if (*edit) {
            track.start_time = (*edit)->media_time;
            const auto play = rescale((*edit)->duration, track.timescale, movie_timescale_value);
            if (!play) {
                return std::unexpected(play.error());
            }
            track.play_time = *play;
            return {};
        }
    }
    const auto info = itunes_gapless_info(movie);
    if (!info) {
        return std::unexpected(info.error());
    }
    if (*info) {
        track.start_time = (*info)->priming;
        track.play_time = (*info)->frames;
    }
    return {};
}

}

auto mp4_media_time(const Mp4Track& track) -> expected<std::uint64_t> {
    std::uint64_t total = 0;
    for (const Mp4TimeRun& run : track.time_runs) {
        const auto span = checked_add(total, static_cast<std::uint64_t>(run.count) * run.delta);
        if (!span) {
            return std::unexpected(span.error());
        }
        total = *span;
    }
    return total;
}

auto mp4_packet_at(const Mp4Track& track, std::uint64_t time) -> expected<Mp4PacketTime> {
    std::size_t index = 0;
    std::uint64_t start = 0;
    for (const Mp4TimeRun& run : track.time_runs) {
        const std::uint64_t span = static_cast<std::uint64_t>(run.count) * run.delta;
        const auto end = checked_add(start, span);
        if (!end) {
            return std::unexpected(end.error());
        }
        if (run.delta != 0 && time < *end) {
            const std::uint64_t into = (time - start) / run.delta;
            return Mp4PacketTime{.index = index + static_cast<std::size_t>(into),
                                 .start = start + (into * run.delta)};
        }
        index += run.count;
        start = *end;
    }
    return Mp4PacketTime{.index = index, .start = start};
}

namespace {

[[nodiscard]] auto read_trak(std::span<const std::byte> trak, std::span<const std::byte> movie,
                             std::uint32_t movie_timescale_value)
    -> expected<std::optional<Mp4Track>> {
    const std::array<std::string_view, 2> table_path{"minf", "stbl"};
    const auto media = find_box(trak, "mdia");
    if (!media) {
        return std::unexpected(media.error());
    }
    if (!*media) {
        return std::optional<Mp4Track>{};
    }
    const auto sound = is_sound((*media)->body);
    if (!sound) {
        return std::unexpected(sound.error());
    }
    if (!*sound) {
        return std::optional<Mp4Track>{};
    }
    const auto table = storage::iso_bmff::descend((*media)->body, table_path);
    if (!table) {
        return std::unexpected(table.error());
    }
    if (!*table) {
        return std::optional<Mp4Track>{};
    }
    const auto entry = sample_entry((*table)->body);
    if (!entry) {
        return std::unexpected(entry.error());
    }
    if (!*entry) {
        return std::optional<Mp4Track>{};
    }
    const auto media_scale = media_timescale((*media)->body);
    if (!media_scale) {
        return std::unexpected(media_scale.error());
    }
    const auto time_runs = read_time_runs((*table)->body);
    if (!time_runs) {
        return std::unexpected(time_runs.error());
    }
    const auto samples = read_samples((*table)->body);
    if (!samples) {
        return std::unexpected(samples.error());
    }
    std::uint64_t sample_total = 0;
    for (const Mp4TimeRun& run : *time_runs) {
        sample_total += run.count;
    }
    if (sample_total != samples->size()) {
        return fail(ErrorCode::parse, "mp4: time runs and sample table disagree");
    }

    Mp4Track track;
    track.codec = (*entry)->codec;
    track.config = (*entry)->config;
    track.channels = (*entry)->channels;
    track.sample_rate = (*entry)->sample_rate;
    track.timescale = *media_scale;
    track.samples = *samples;
    track.time_runs = *time_runs;
    const auto bounds = apply_gapless_bounds(track, trak, movie, movie_timescale_value);
    if (!bounds) {
        return std::unexpected(bounds.error());
    }
    return std::optional<Mp4Track>(std::move(track));
}

}

auto mp4_read_track(const storage::ReadableSource& source) -> expected<Mp4Track> {
    auto movie = storage::iso_bmff::read_movie(source);
    if (!movie) {
        return std::unexpected(movie.error());
    }
    const auto timescale = movie_timescale(*movie);
    if (!timescale) {
        return std::unexpected(timescale.error());
    }

    Iterator traks(*movie);
    while (true) {
        const auto trak = traks.next();
        if (!trak) {
            return std::unexpected(trak.error());
        }
        if (!*trak) {
            break;
        }
        if (!(*trak)->is("trak")) {
            continue;
        }
        const auto track = read_trak((*trak)->body, *movie, *timescale);
        if (!track) {
            return std::unexpected(track.error());
        }
        if (*track) {
            return **track;
        }
    }
    return fail(ErrorCode::not_found, "mp4: no audio track");
}

namespace {

struct Output {
    std::string_view codec;
    std::uint32_t sample_rate = 0;
    std::uint16_t channels = 0;
    std::optional<std::uint16_t> bit_depth;
};

class BitReader {
public:
    explicit BitReader(std::span<const std::byte> bytes) : bytes_(bytes) {}

    [[nodiscard]] auto read(unsigned count) -> std::optional<std::uint32_t> {
        std::uint32_t value = 0;
        for (unsigned index = 0; index < count; ++index) {
            const std::size_t byte = position_ / 8;
            if (byte >= bytes_.size()) {
                return std::nullopt;
            }
            const auto bit = (std::to_integer<unsigned>(bytes_[byte]) >>
                              (7U - static_cast<unsigned>(position_ % 8))) &
                             1U;
            value = (value << 1U) | bit;
            ++position_;
        }
        return value;
    }

private:
    std::span<const std::byte> bytes_;
    std::size_t position_ = 0;
};

[[nodiscard]] auto object_type(BitReader& bits) -> std::optional<std::uint32_t> {
    const auto value = bits.read(5);
    if (!value) {
        return std::nullopt;
    }
    if (*value != 31) {
        return value;
    }
    const auto extended = bits.read(6);
    if (!extended) {
        return std::nullopt;
    }
    return 32 + *extended;
}

[[nodiscard]] auto sampling_rate(BitReader& bits) -> std::optional<std::uint32_t> {
    const auto index = bits.read(4);
    if (!index) {
        return std::nullopt;
    }
    if (*index == 15) {
        return bits.read(24);
    }
    if (*index >= mp4_sampling_rates.size()) {
        return std::nullopt;
    }
    return mp4_sampling_rates[*index];
}

[[nodiscard]] auto aac_output(std::span<const std::byte> config, const Mp4Track& track) -> Output {
    BitReader bits(config);
    const Output fallback{.codec = "aac",
                          .sample_rate = track.timescale,
                          .channels = track.channels,
                          .bit_depth = std::nullopt};
    auto type = object_type(bits);
    if (!type) {
        return fallback;
    }
    auto rate = sampling_rate(bits);
    if (!rate) {
        return fallback;
    }
    const auto channel_config = bits.read(4);
    if (!channel_config) {
        return fallback;
    }
    bool stereo_from_ps = false;
    if (*type == 5 || *type == 29) {
        stereo_from_ps = *type == 29;
        const auto extended_rate = sampling_rate(bits);
        if (!extended_rate) {
            return fallback;
        }
        rate = extended_rate;
        const auto extended_type = object_type(bits);
        if (!extended_type) {
            return fallback;
        }
        type = extended_type;
    } else {
        if (track.timescale == *rate * 2U) {
            rate = track.timescale;
        }
    }
    std::uint16_t channels = track.channels;
    if (stereo_from_ps) {
        channels = 2;
    } else {
        if (*channel_config >= 1 && *channel_config <= 6) {
            channels = static_cast<std::uint16_t>(*channel_config);
        } else {
            if (*channel_config == 7) {
                channels = 8;
            }
        }
    }
    return Output{
        .codec = "aac", .sample_rate = *rate, .channels = channels, .bit_depth = std::nullopt};
}

}

auto mp4_probe_track(const Mp4Track& track) -> expected<Properties> {
    Output output;
    if (track.codec == Mp4Codec::alac) {
        const auto rate = storage::iso_bmff::integer<std::uint32_t>(track.config, 20);
        if (!rate) {
            return std::unexpected(rate.error());
        }
        output = Output{.codec = "alac",
                        .sample_rate = *rate,
                        .channels = std::to_integer<std::uint8_t>(track.config[9]),
                        .bit_depth = std::to_integer<std::uint8_t>(track.config[5])};
    } else {
        output = aac_output(track.config, track);
    }
    if (output.sample_rate == 0 || output.channels == 0) {
        return fail(ErrorCode::parse, "mp4: invalid output format");
    }
    const auto start = rescale(track.start_time, output.sample_rate, track.timescale);
    const auto total = mp4_media_time(track);
    if (!start || !total) {
        return fail(ErrorCode::parse, "mp4: invalid timeline");
    }
    const auto total_frames = rescale(*total, output.sample_rate, track.timescale);
    if (!total_frames) {
        return std::unexpected(total_frames.error());
    }
    const std::uint64_t available = *total_frames > *start ? *total_frames - *start : 0;
    std::uint64_t frames = available;
    if (track.play_time) {
        const auto play = rescale(*track.play_time, output.sample_rate, track.timescale);
        if (!play) {
            return std::unexpected(play.error());
        }
        frames = std::min(*play, available);
    }
    Properties properties;
    properties.codec = output.codec;
    properties.sample_rate = output.sample_rate;
    properties.channels = output.channels;
    properties.bit_depth = output.bit_depth;
    const auto duration = rescale(frames, 1000, output.sample_rate);
    if (!duration) {
        return std::unexpected(duration.error());
    }
    properties.duration_ms = *duration;
    return properties;
}

auto mp4_probe(const storage::ReadableSource& source) -> expected<Properties> {
    auto track = mp4_read_track(source);
    if (!track) {
        return std::unexpected(track.error());
    }
    return mp4_probe_track(*track);
}

namespace {

class Mp4Decoder final : public Decoder {
public:
    static auto create(const storage::ReadableSource& source, Mp4Track track)
        -> expected<std::unique_ptr<Decoder>> {
        auto decoder = std::make_unique<Mp4Decoder>(Passkey{}, source, std::move(track));
        const auto engine = decoder->initialize_engine();
        if (!engine) {
            return std::unexpected(engine.error());
        }
        const auto timeline = decoder->initialize_timeline();
        if (!timeline) {
            return std::unexpected(timeline.error());
        }
        decoder->initialize_metadata();
        return decoder;
    }

    ~Mp4Decoder() override = default;

    [[nodiscard]] auto has_integer_samples() const -> bool override {
        return engine_ != nullptr && engine_->has_integer_samples();
    }

    [[nodiscard]] auto read_frames_impl(std::span<float> output) -> expected<std::size_t> override {
        const auto taken = take(output.size());
        if (!taken) {
            return std::unexpected(taken.error());
        }
        ORCA_ASSERT(engine_ != nullptr);
        ORCA_ASSERT(engine_->channels != 0);
        const std::size_t channels = engine_->channels;
        if (engine_->has_integer_samples()) {
            for (std::size_t index = 0; index < taken->samples; ++index) {
                output[index] = integer_sample_to_float(integers_[taken->start + index]);
            }
        } else {
            std::copy_n(pcm_.data() + taken->start, taken->samples, output.data());
        }
        return taken->samples / channels;
    }

    [[nodiscard]] auto read_frames_i32_impl(std::span<std::int32_t> output)
        -> expected<std::size_t> override {
        const auto taken = take(output.size());
        if (!taken) {
            return std::unexpected(taken.error());
        }
        std::copy_n(integers_.data() + taken->start, taken->samples, output.data());
        return taken->samples / engine_->channels;
    }

    [[nodiscard]] auto seek(std::uint64_t frame) -> expected<void> override {
        if (frame >= total_frames_) {
            remaining_frames_ = 0;
            pending_start_ = 0;
            pending_end_ = 0;
            return {};
        }
        return position(frame);
    }

private:
    [[nodiscard]] auto initialize_engine() -> expected<void> {
        auto engine = open_engine();
        if (!engine) {
            return std::unexpected(engine.error());
        }
        engine_ = std::move(*engine);
        if (engine_->channels == 0 || engine_->sample_rate == 0) {
            return fail(ErrorCode::parse, "mp4: invalid engine format");
        }
        std::uint32_t largest = 0;
        for (const Mp4Sample& sample : track_.samples) {
            largest = std::max(largest, sample.size);
        }
        if (largest > mp4_max_packet_bytes) {
            return fail(ErrorCode::parse, "mp4: packet too large");
        }
        packet_.resize(largest);
        const std::size_t packet_samples =
            static_cast<std::size_t>(engine_->max_packet_frames) * engine_->channels;
        if (engine_->has_integer_samples()) {
            integers_.resize(packet_samples);
        } else {
            pcm_.resize(packet_samples);
        }
        return {};
    }

    [[nodiscard]] auto initialize_timeline() -> expected<void> {
        const auto start = to_frames(track_.start_time);
        const auto total = mp4_media_time(track_);
        if (!start || !total) {
            return fail(ErrorCode::parse, "mp4: invalid timeline");
        }
        start_frame_ = *start;
        const auto total_frames = to_frames(*total);
        if (!total_frames) {
            return std::unexpected(total_frames.error());
        }
        const std::uint64_t available =
            *total_frames > start_frame_ ? *total_frames - start_frame_ : 0;
        total_frames_ = available;
        if (track_.play_time) {
            const auto play = to_frames(*track_.play_time);
            if (!play) {
                return std::unexpected(play.error());
            }
            total_frames_ = std::min(*play, available);
        }
        return position(0);
    }

    void initialize_metadata() {
        codec = track_.codec == Mp4Codec::alac ? "alac" : "aac";
        if (engine_->bits_per_sample) {
            const std::uint16_t bits = *engine_->bits_per_sample;
            source_format = PcmFormat{.sample_format = sample_format_for_bits(bits),
                                      .channels = engine_->channels,
                                      .sample_rate = engine_->sample_rate,
                                      .bits_per_sample = bits,
                                      .bytes_per_frame = static_cast<std::uint16_t>(
                                          engine_->channels * ((bits + 7U) / 8U))};
        }
        format = PcmFormat{.sample_format = SampleFormat::float_32,
                           .channels = engine_->channels,
                           .sample_rate = engine_->sample_rate,
                           .bits_per_sample = 32,
                           .bytes_per_frame = static_cast<std::uint16_t>(engine_->channels * 4U)};
        frame_count = total_frames_;
    }

public:
    struct Passkey {
    private:
        friend class Mp4Decoder;
        Passkey() = default;
    };

    Mp4Decoder(Passkey key, const storage::ReadableSource& source, Mp4Track track)
        : source_(&source), track_(std::move(track)) {
        (void)key;
    }

private:
    [[nodiscard]] auto open_engine() -> expected<std::unique_ptr<Engine>> {
        if (track_.codec == Mp4Codec::alac) {
            return open_alac_engine(track_.config);
        }
        if (track_.samples.empty()) {
            return fail(ErrorCode::parse, "mp4: no packets for AAC");
        }
        const Mp4Sample first = track_.samples.front();
        if (first.size > mp4_max_packet_bytes) {
            return fail(ErrorCode::parse, "mp4: first packet too large");
        }
        std::vector<std::byte> unit(first.size);
        if (!unit.empty()) {
            const auto read = source_->read_at(first.offset, unit);
            if (!read || *read != unit.size()) {
                return fail(ErrorCode::parse, "mp4: truncated first packet");
            }
        }
        return open_aac_engine(track_.config, unit);
    }

    [[nodiscard]] auto to_frames(std::uint64_t time) -> expected<std::uint64_t> {
        return rescale(time, engine_->sample_rate, track_.timescale);
    }

    [[nodiscard]] auto to_time(std::uint64_t frames) -> expected<std::uint64_t> {
        return rescale(frames, track_.timescale, engine_->sample_rate);
    }

    [[nodiscard]] auto packet_start(std::size_t index) -> expected<std::uint64_t> {
        std::size_t remaining = index;
        std::uint64_t start = 0;
        for (const Mp4TimeRun& run : track_.time_runs) {
            const std::size_t taken = std::min(remaining, static_cast<std::size_t>(run.count));
            const auto advanced = checked_add(start, static_cast<std::uint64_t>(taken) * run.delta);
            if (!advanced) {
                return std::unexpected(advanced.error());
            }
            start = *advanced;
            remaining -= taken;
            if (remaining == 0) {
                break;
            }
        }
        return start;
    }

    [[nodiscard]] auto position(std::uint64_t frame) -> expected<void> {
        const auto target = checked_add(start_frame_, frame);
        if (!target) {
            return std::unexpected(target.error());
        }
        const auto time = to_time(*target);
        if (!time) {
            return std::unexpected(time.error());
        }
        const auto found = mp4_packet_at(track_, *time);
        if (!found) {
            return std::unexpected(found.error());
        }
        const std::size_t first =
            found->index > engine_->preroll_packets ? found->index - engine_->preroll_packets : 0;
        const auto first_start = packet_start(first);
        if (!first_start) {
            return std::unexpected(first_start.error());
        }
        const auto first_frames = to_frames(*first_start);
        if (!first_frames) {
            return std::unexpected(first_frames.error());
        }
        (*engine_).reset();
        next_packet_ = first;
        skip_frames_ = *target - std::min(*target, *first_frames);
        remaining_frames_ = total_frames_ > frame ? total_frames_ - frame : 0;
        pending_start_ = 0;
        pending_end_ = 0;
        return {};
    }

    template <typename Sample>
    [[nodiscard]] auto align_to_packet(std::span<Sample> buffer, std::size_t index,
                                       std::uint64_t frames) -> expected<std::uint64_t> {
        if (index + 1 >= track_.samples.size()) {
            return frames;
        }
        const auto next_start = packet_start(index + 1);
        const auto this_start = packet_start(index);
        if (!next_start || !this_start) {
            return fail(ErrorCode::parse, "mp4: packet time overflow");
        }
        const auto expected = to_frames(*next_start - *this_start);
        if (!expected) {
            return std::unexpected(expected.error());
        }
        const std::size_t capacity = buffer.size() / engine_->channels;
        if (frames >= *expected || *expected > capacity) {
            return frames;
        }
        const std::size_t channels = engine_->channels;
        const auto decoded_frames = static_cast<std::size_t>(frames);
        const auto missing = static_cast<std::size_t>(*expected - frames);
        std::memmove(buffer.data() + (missing * channels), buffer.data(),
                     decoded_frames * channels * sizeof(Sample));
        std::memset(buffer.data(), 0, (missing * channels) * sizeof(Sample));
        return *expected;
    }

    struct Taken {
        std::size_t start = 0;
        std::size_t samples = 0;
    };

    [[nodiscard]] auto take(std::size_t capacity) -> expected<Taken> {
        const std::size_t channels = engine_->channels;
        if (remaining_frames_ == 0) {
            return Taken{};
        }
        if (pending_start_ == pending_end_) {
            const auto decoded = decode_next();
            if (!decoded) {
                return std::unexpected(decoded.error());
            }
            if (!*decoded) {
                return Taken{};
            }
        }
        const std::size_t pending = (pending_end_ - pending_start_) / channels;
        const auto frames =
            std::min({static_cast<std::uint64_t>(pending),
                      static_cast<std::uint64_t>(capacity / channels), remaining_frames_});
        const Taken taken{.start = pending_start_,
                          .samples = static_cast<std::size_t>(frames) * channels};
        pending_start_ += taken.samples;
        remaining_frames_ -= frames;
        return taken;
    }

    [[nodiscard]] auto decode_next() -> expected<bool> {
        while (next_packet_ < track_.samples.size()) {
            const std::size_t index = next_packet_;
            ++next_packet_;
            const Mp4Sample sample = track_.samples[index];
            if (sample.size > packet_.size()) {
                return fail(ErrorCode::parse, "mp4: packet larger than table");
            }
            if (sample.size != 0) {
                const auto read = source_->read_at(
                    sample.offset, std::span<std::byte>(packet_.data(), sample.size));
                if (!read || *read != sample.size) {
                    return fail(ErrorCode::parse, "mp4: truncated packet");
                }
            }
            const std::span<const std::byte> packet(packet_.data(), sample.size);
            std::uint64_t frames = 0;
            if (engine_->has_integer_samples()) {
                const auto decoded = engine_->decode_i32(packet, integers_);
                if (!decoded) {
                    return std::unexpected(decoded.error());
                }
                const auto aligned = align_to_packet<int32_t>(integers_, index, *decoded);
                if (!aligned) {
                    return std::unexpected(aligned.error());
                }
                frames = *aligned;
            } else {
                const auto decoded = engine_->decode(packet, pcm_);
                if (!decoded) {
                    return std::unexpected(decoded.error());
                }
                const auto aligned = align_to_packet<float>(pcm_, index, *decoded);
                if (!aligned) {
                    return std::unexpected(aligned.error());
                }
                frames = *aligned;
            }
            const std::uint64_t dropped = std::min(frames, skip_frames_);
            skip_frames_ -= dropped;
            if (frames == dropped) {
                continue;
            }
            const std::size_t channels = engine_->channels;
            pending_start_ = static_cast<std::size_t>(dropped * channels);
            pending_end_ = static_cast<std::size_t>(frames) * channels;
            return true;
        }
        return false;
    }

    const storage::ReadableSource* source_;
    Mp4Track track_;
    std::unique_ptr<Engine> engine_;
    std::vector<std::byte> packet_;
    std::vector<float> pcm_;
    std::vector<std::int32_t> integers_;
    std::size_t pending_start_ = 0;
    std::size_t pending_end_ = 0;
    std::size_t next_packet_ = 0;
    std::uint64_t skip_frames_ = 0;
    std::uint64_t remaining_frames_ = 0;
    std::uint64_t start_frame_ = 0;
    std::uint64_t total_frames_ = 0;
};

}

auto mp4_open_track(const storage::ReadableSource& source, Mp4Track track)
    -> expected<std::unique_ptr<Decoder>> {
    return Mp4Decoder::create(source, std::move(track));
}

auto mp4_open(const storage::ReadableSource& source) -> expected<std::unique_ptr<Decoder>> {
    auto track = mp4_read_track(source);
    if (!track) {
        return std::unexpected(track.error());
    }
    return mp4_open_track(source, std::move(*track));
}
}
