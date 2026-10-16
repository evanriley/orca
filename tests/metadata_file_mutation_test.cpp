#include "liborca/base/path.hpp"
#include "liborca/codec/registry.hpp"
#include "liborca/metadata/file_mutation.hpp"
#include "liborca/metadata/id3v1.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <doctest/doctest.h>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

using orca::metadata::Field;
using orca::metadata::file_mutation::backup_path;
using orca::metadata::file_mutation::commit_move;
using orca::metadata::file_mutation::commit_replacement;
using orca::metadata::file_mutation::commit_replacement_interrupted;
using orca::metadata::file_mutation::copy_verified;
using orca::metadata::file_mutation::identity;
using orca::metadata::file_mutation::Interrupt;
using orca::metadata::file_mutation::is_orca_temporary_name;
using orca::metadata::file_mutation::plan_backup_directory;
using orca::metadata::file_mutation::require_writable_file;
using orca::metadata::file_mutation::restore_from_backup;
using orca::metadata::file_mutation::restore_from_backup_interrupted;
using orca::metadata::file_mutation::sibling_path;
using orca::metadata::file_mutation::stage_flac;
using orca::metadata::file_mutation::stage_mpeg;
using orca::metadata::mutation::Change;
using orca::metadata::mutation::FileIdentity;

auto workspace() -> std::filesystem::path {
    const auto directory = std::filesystem::temp_directory_path() / "orca-file-mutation-test";
    std::filesystem::remove_all(directory);
    std::filesystem::create_directories(directory);
    return directory;
}

auto read_file_bytes(const std::filesystem::path& path) -> std::vector<std::byte> {
    std::ifstream input(path, std::ios::binary);
    REQUIRE(input.good());
    input.seekg(0, std::ios::end);
    const std::streamoff size = input.tellg();
    input.seekg(0, std::ios::beg);
    std::vector<std::byte> bytes(static_cast<std::size_t>(size));
    input.read(reinterpret_cast<char*>(bytes.data()), size);
    return bytes;
}

auto legacy_trailer(std::string_view title) -> std::string {
    const auto encoded =
        orca::metadata::id3v1::encode(orca::metadata::id3v1::Tag{.title = title,
                                                                 .artist = "Generated artist",
                                                                 .album = "Generated album",
                                                                 .year = "2026",
                                                                 .comment = "Generated",
                                                                 .track_number = 1,
                                                                 .genre = 13});
    REQUIRE(encoded.has_value());
    return std::string(reinterpret_cast<const char*>(encoded->data()), encoded->size());
}

auto mpeg_source(std::string_view title) -> std::string {
    std::string bytes = "\xff\xfb\x90\x64generated audio payload";
    bytes += legacy_trailer(title);
    return bytes;
}

auto write_long_mpeg(const std::filesystem::path& path, std::string_view title) {
    std::string bytes = "\xff\xfb\x90\x64";
    bytes.append(16 * 16 * 1024, static_cast<char>(0x55));
    bytes += legacy_trailer(title);
    REQUIRE(orca::fs::write_file(path, bytes).has_value());
}

void expect_title(const std::filesystem::path& path, std::string_view expected) {
    const auto bytes = read_file_bytes(path);
    REQUIRE(bytes.size() >= 128);
    std::array<std::byte, 128> trailer{};
    std::memcpy(trailer.data(), bytes.data() + bytes.size() - 128, 128);
    const auto parsed = orca::metadata::id3v1::parse(trailer);
    REQUIRE(parsed.has_value());
    CHECK(parsed->title == expected);
}

void forge_in_place_edit(const std::filesystem::path& path, std::uint64_t offset,
                         std::string_view replacement) {
    struct stat before{};
    REQUIRE(::stat(path.c_str(), &before) == 0);
    const int descriptor = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
    REQUIRE(descriptor >= 0);
    REQUIRE(::pwrite(descriptor, replacement.data(), replacement.size(),
                     static_cast<off_t>(offset)) == static_cast<ssize_t>(replacement.size()));
    timespec times[2]{before.st_atim, before.st_mtim};
    REQUIRE(::futimens(descriptor, times) == 0);
    ::close(descriptor);
    struct stat after{};
    REQUIRE(::stat(path.c_str(), &after) == 0);
    CHECK(after.st_size == before.st_size);
    CHECK(after.st_mtim.tv_sec == before.st_mtim.tv_sec);
    CHECK(after.st_mtim.tv_nsec == before.st_mtim.tv_nsec);
}

auto build_flac_source(const std::vector<std::string>& entries, const std::string& audio)
    -> std::string {
    std::string stream = "fLaC";
    stream.push_back('\0');
    stream.push_back('\0');
    stream.push_back('\0');
    stream.push_back(static_cast<char>(34));
    stream.append(34, '\0');
    std::string comments;
    const std::string vendor = "Generated";
    const auto put_u32 = [&comments](std::uint32_t value) {
        for (std::size_t index = 0; index < 4; ++index) {
            comments.push_back(static_cast<char>((value >> (index * 8U)) & 0xffU));
        }
    };
    put_u32(static_cast<std::uint32_t>(vendor.size()));
    comments += vendor;
    put_u32(static_cast<std::uint32_t>(entries.size()));
    for (const auto& entry : entries) {
        put_u32(static_cast<std::uint32_t>(entry.size()));
        comments += entry;
    }
    stream.push_back(static_cast<char>(0x84));
    const std::uint32_t length = static_cast<std::uint32_t>(comments.size());
    stream.push_back(static_cast<char>((length >> 16U) & 0xffU));
    stream.push_back(static_cast<char>((length >> 8U) & 0xffU));
    stream.push_back(static_cast<char>(length & 0xffU));
    stream += comments;
    stream += audio;
    return stream;
}

}

TEST_CASE("the on-disk temporary and backup names match the mutation layout") {
    CHECK(sibling_path("/music/source.mp3", "stage", 7, 0) == "/music/.source.mp3.orca-stage-7-0");
    CHECK(sibling_path("/music/source.flac", "restore", 9, 2) ==
          "/music/.source.flac.orca-restore-9-2");
    CHECK(plan_backup_directory("/backup", 7) == "/backup/7");
    CHECK(backup_path("/backup/7", 0, "/music/source.mp3") == "/backup/7/0-source.mp3");

    CHECK(is_orca_temporary_name("song.mp3.orca-stage-7-0"));
    CHECK(is_orca_temporary_name("song.mp3.orca-backup-7-0"));
    CHECK(is_orca_temporary_name(".song.mp3.orca-restore-7-0"));
    CHECK(is_orca_temporary_name("song.mp3.recovery-displaced"));
    CHECK(is_orca_temporary_name(".source.mp3.orca-stage-1000-0"));
    CHECK_FALSE(is_orca_temporary_name("song.mp3"));
    CHECK_FALSE(is_orca_temporary_name("song.orca-stage"));
    CHECK_FALSE(is_orca_temporary_name("orca-stage-7-0"));
}

TEST_CASE("copy_verified preserves permission bits and identity, and detects a change") {
    const auto directory = workspace();
    const auto source = directory / "source.bin";
    const auto copy = directory / "copy.bin";
    REQUIRE(orca::fs::write_file(source, "mutation payload").has_value());
    std::filesystem::permissions(source, std::filesystem::perms::owner_read |
                                             std::filesystem::perms::owner_write |
                                             std::filesystem::perms::group_read);

    const auto original = identity(source);
    REQUIRE(original.has_value());
    REQUIRE(copy_verified(source, copy, *original).has_value());

    CHECK(std::filesystem::status(copy).permissions() ==
          std::filesystem::status(source).permissions());
    const auto copied = identity(copy);
    REQUIRE(copied.has_value());
    CHECK(copied->eql(*original));
    CHECK(require_writable_file(source).has_value());

    REQUIRE(orca::fs::write_file(source, "mutation payload changed").has_value());
    const auto changed = orca::metadata::file_mutation::matches(source, *original);
    REQUIRE(changed.has_value());
    CHECK_FALSE(*changed);

    std::filesystem::remove_all(directory);
}

TEST_CASE("require_writable_file refuses a file with no write bit") {
    const auto directory = workspace();
    const auto file = directory / "read-only.bin";
    REQUIRE(orca::fs::write_file(file, "read only").has_value());
    std::filesystem::permissions(file, std::filesystem::perms::owner_read |
                                           std::filesystem::perms::group_read |
                                           std::filesystem::perms::others_read);

    const auto refused = require_writable_file(file);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::file_read_only);

    std::filesystem::permissions(file, std::filesystem::perms::owner_all);
    CHECK(require_writable_file(file).has_value());

    std::filesystem::remove_all(directory);
}

TEST_CASE("a replacement keeps an identical backup and a restore puts the original back") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto stage = directory / "stage.mp3";
    const auto backup = directory / "backup.mp3";
    const auto restore_path = directory / ".restore.mp3";
    REQUIRE(orca::fs::write_file(source, mpeg_source("Old title")).has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_mpeg(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());
    CHECK(expected->eql(*identity(source)));

    REQUIRE(commit_replacement(source, stage, backup, *expected).has_value());
    expect_title(source, "New title");
    CHECK(expected->eql(*identity(backup)));
    CHECK_FALSE(std::filesystem::exists(stage));

    const auto replaced = identity(source);
    REQUIRE(replaced.has_value());
    REQUIRE(restore_from_backup(source, backup, restore_path, *expected, *replaced).has_value());
    CHECK(expected->eql(*identity(source)));
    CHECK_FALSE(std::filesystem::exists(restore_path));
    CHECK(expected->eql(*identity(backup)));

    std::filesystem::remove_all(directory);
}

TEST_CASE("a restore leaves alone a source that changed after the write") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto stage = directory / "stage.mp3";
    const auto backup = directory / "backup.mp3";
    const auto restore_path = directory / ".restore.mp3";
    REQUIRE(orca::fs::write_file(source, mpeg_source("Old title")).has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_mpeg(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());
    REQUIRE(commit_replacement(source, stage, backup, *expected).has_value());
    const auto replaced = identity(source);
    REQUIRE(replaced.has_value());
    forge_in_place_edit(source, 0, "GENERATED");

    const auto refused = restore_from_backup(source, backup, restore_path, *expected, *replaced);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::file_identity_changed);
    expect_title(source, "New title");
    CHECK_FALSE(std::filesystem::exists(restore_path));
    CHECK(expected->eql(*identity(backup)));

    std::filesystem::remove_all(directory);
}

TEST_CASE("a copy that does not come out as the expected identity is deleted") {
    const auto directory = workspace();
    const auto source = directory / "source.bin";
    const auto copy = directory / "copy.bin";
    REQUIRE(orca::fs::write_file(source, "generated bytes").has_value());
    auto expected = identity(source);
    REQUIRE(expected.has_value());
    expected->quick_hash[0] = static_cast<std::uint8_t>(expected->quick_hash[0] ^ 1);

    const auto refused = copy_verified(source, copy, *expected);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::copy_identity_mismatch);
    CHECK_FALSE(std::filesystem::exists(copy));

    std::filesystem::remove_all(directory);
}

TEST_CASE("FLAC replacement rewrites comments and preserves audio bytes") {
    const auto directory = workspace();
    const auto source = directory / "source.flac";
    const auto stage = directory / "stage.flac";
    REQUIRE(orca::fs::write_file(source,
                                 build_flac_source({"TITLE=Old title"}, "generated audio frames"))
                .has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_flac(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());

    const auto staged = read_file_bytes(stage);
    const std::string_view text(reinterpret_cast<const char*>(staged.data()), staged.size());
    CHECK(text.find("TITLE=New title") != std::string_view::npos);
    CHECK(text.ends_with("generated audio frames"));

    std::filesystem::remove_all(directory);
}

TEST_CASE(
    "FLAC replacement writes a comment block longer than one length byte with its full length") {
    const auto directory = workspace();
    const auto source = directory / "source.flac";
    const auto stage = directory / "stage.flac";
    const std::string long_entry = "CUSTOM=" + std::string(70000, 'x');
    REQUIRE(orca::fs::write_file(source, build_flac_source({"TITLE=Old title", long_entry},
                                                           "generated audio frames"))
                .has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_flac(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());

    const auto staged = read_file_bytes(stage);
    REQUIRE(staged.size() > 46);
    const std::uint32_t block_length =
        (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(staged[43])) << 16U) |
        (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(staged[44])) << 8U) |
        static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(staged[45]));
    REQUIRE(staged.size() >= static_cast<std::size_t>(46) + block_length);
    const std::string_view block(reinterpret_cast<const char*>(staged.data() + 46), block_length);
    CHECK(block.find("TITLE=New title") != std::string_view::npos);
    CHECK(block.find(long_entry) != std::string_view::npos);
    const std::string_view tail(reinterpret_cast<const char*>(staged.data() + 46 + block_length),
                                staged.size() - 46 - block_length);
    CHECK(tail == "generated audio frames");

    std::filesystem::remove_all(directory);
}

TEST_CASE("staging rejects a same-size edit that preserved the modification time") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto stage = directory / "stage.mp3";
    REQUIRE(orca::fs::write_file(source, mpeg_source("Old title")).has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    forge_in_place_edit(source, 0, "GENERATED");
    CHECK_FALSE(expected->eql(*identity(source)));

    const auto refused = stage_mpeg(
        source, stage, *expected,
        {Change{.field = Field::title, .before = "Old title", .after = "New title"}}, std::nullopt);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::file_identity_changed);

    std::filesystem::remove_all(directory);
}

TEST_CASE("commit refuses to replace a source edited between staging and rename") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto stage = directory / "stage.mp3";
    const auto backup = directory / "backup.mp3";
    REQUIRE(orca::fs::write_file(source, mpeg_source("Old title")).has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_mpeg(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());
    forge_in_place_edit(source, 0, "GENERATED");

    const auto refused = commit_replacement(source, stage, backup, *expected);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::file_identity_changed);
    expect_title(source, "Old title");
    CHECK_FALSE(std::filesystem::exists(backup));

    std::filesystem::remove_all(directory);
}

TEST_CASE("commit refuses a source whose middle changed past the quick hash") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto stage = directory / "stage.mp3";
    const auto backup = directory / "backup.mp3";
    write_long_mpeg(source, "Old title");
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_mpeg(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());
    forge_in_place_edit(source, expected->size_bytes / 2, "GENERATED");
    const auto edited = identity(source);
    REQUIRE(edited.has_value());
    CHECK(expected->quick_hash == edited->quick_hash);

    const auto refused = commit_replacement(source, stage, backup, *expected);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::file_identity_changed);
    CHECK(edited->eql(*identity(source)));
    CHECK_FALSE(std::filesystem::exists(backup));

    std::filesystem::remove_all(directory);
}

TEST_CASE("an interrupted commit after the backup leaves the original in place") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto stage = directory / "stage.mp3";
    const auto backup = directory / "backup.mp3";
    REQUIRE(orca::fs::write_file(source, mpeg_source("Old title")).has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_mpeg(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());

    const auto interrupted = commit_replacement_interrupted(source, stage, backup, *expected,
                                                            Interrupt::after_backup_copy);
    REQUIRE_FALSE(interrupted.has_value());
    CHECK(interrupted.error().code == orca::ErrorCode::simulated_power_loss);
    expect_title(source, "Old title");
    CHECK(expected->eql(*identity(backup)));
    CHECK(std::filesystem::exists(stage));

    std::filesystem::remove_all(directory);
}

TEST_CASE("an interrupted commit after the rename leaves the new source and the backup") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto stage = directory / "stage.mp3";
    const auto backup = directory / "backup.mp3";
    REQUIRE(orca::fs::write_file(source, mpeg_source("Old title")).has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_mpeg(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());

    const auto interrupted = commit_replacement_interrupted(source, stage, backup, *expected,
                                                            Interrupt::after_source_rename);
    REQUIRE_FALSE(interrupted.has_value());
    CHECK(interrupted.error().code == orca::ErrorCode::simulated_power_loss);
    expect_title(source, "New title");
    CHECK(expected->eql(*identity(backup)));
    CHECK_FALSE(std::filesystem::exists(stage));

    std::filesystem::remove_all(directory);
}

TEST_CASE("an interrupted restore after the copy leaves the new source in place") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto stage = directory / "stage.mp3";
    const auto backup = directory / "backup.mp3";
    const auto restore_path = directory / ".restore.mp3";
    REQUIRE(orca::fs::write_file(source, mpeg_source("Old title")).has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_mpeg(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());
    REQUIRE(commit_replacement(source, stage, backup, *expected).has_value());
    const auto replaced = identity(source);
    REQUIRE(replaced.has_value());

    const auto interrupted = restore_from_backup_interrupted(
        source, backup, restore_path, *expected, *replaced, Interrupt::after_restore_copy);
    REQUIRE_FALSE(interrupted.has_value());
    CHECK(interrupted.error().code == orca::ErrorCode::simulated_power_loss);
    expect_title(source, "New title");
    CHECK(expected->eql(*identity(restore_path)));
    CHECK(expected->eql(*identity(backup)));

    std::filesystem::remove_all(directory);
}

TEST_CASE("an interrupted restore after the rename leaves the original in place") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto stage = directory / "stage.mp3";
    const auto backup = directory / "backup.mp3";
    const auto restore_path = directory / ".restore.mp3";
    REQUIRE(orca::fs::write_file(source, mpeg_source("Old title")).has_value());
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(stage_mpeg(source, stage, *expected,
                       {Change{.field = Field::title, .before = "Old title", .after = "New title"}},
                       std::nullopt)
                .has_value());
    REQUIRE(commit_replacement(source, stage, backup, *expected).has_value());
    const auto replaced = identity(source);
    REQUIRE(replaced.has_value());

    const auto interrupted = restore_from_backup_interrupted(
        source, backup, restore_path, *expected, *replaced, Interrupt::after_restore_rename);
    REQUIRE_FALSE(interrupted.has_value());
    CHECK(interrupted.error().code == orca::ErrorCode::simulated_power_loss);
    CHECK(expected->eql(*identity(source)));
    CHECK_FALSE(std::filesystem::exists(restore_path));
    CHECK(expected->eql(*identity(backup)));

    std::filesystem::remove_all(directory);
}

TEST_CASE("commit_move moves a file and refuses to replace an existing destination") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto destination = directory / "destination.mp3";
    REQUIRE(orca::fs::write_file(source, "payload").has_value());
    REQUIRE(commit_move(source, destination).has_value());
    CHECK_FALSE(std::filesystem::exists(source));
    CHECK(orca::fs::read_file(destination, 1024).value() == "payload");

    const auto second = directory / "second.mp3";
    const auto existing = directory / "existing.mp3";
    REQUIRE(orca::fs::write_file(second, "second").has_value());
    REQUIRE(orca::fs::write_file(existing, "existing").has_value());
    const auto refused = commit_move(second, existing);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::destination_exists);
    CHECK(orca::fs::read_file(second, 1024).value() == "second");
    CHECK(orca::fs::read_file(existing, 1024).value() == "existing");

    std::filesystem::remove_all(directory);
}

TEST_CASE("a copy whose content differs from the expected content is deleted") {
    const auto directory = workspace();
    const auto source = directory / "source.mp3";
    const auto copy = directory / "copy.mp3";
    write_long_mpeg(source, "Old title");
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    forge_in_place_edit(source, expected->size_bytes / 2, "GENERATED");
    const auto edited = identity(source);
    REQUIRE(edited.has_value());
    CHECK(expected->quick_hash == edited->quick_hash);
    CHECK_FALSE(expected->content_hash == edited->content_hash);

    const auto refused = copy_verified(source, copy, *expected);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::copy_identity_mismatch);
    CHECK_FALSE(std::filesystem::exists(copy));

    std::filesystem::remove_all(directory);
}

TEST_CASE("a staged FLAC decodes to the same PCM as its source") {
    const auto directory = workspace();
    const auto source = directory / "source.flac";
    const auto stage = directory / "stage.flac";
    std::filesystem::copy_file(std::filesystem::path(ORCA_SOURCE_DIR) / "fixtures" / "audio" /
                                   "generated-reference.flac",
                               source);
    const auto expected = identity(source);
    REQUIRE(expected.has_value());
    REQUIRE(
        stage_flac(
            source, stage, *expected,
            {Change{.field = Field::title, .before = std::nullopt, .after = "Generated reference"}},
            std::nullopt)
            .has_value());

    auto source_file = orca::storage::LocalFileSource::open(source);
    auto staged_file = orca::storage::LocalFileSource::open(stage);
    REQUIRE(source_file.has_value());
    REQUIRE(staged_file.has_value());
    const auto registry = orca::codec::CodecRegistry::builtins();
    auto source_decoder = registry.open_detected(*source_file);
    auto staged_decoder = registry.open_detected(*staged_file);
    REQUIRE(source_decoder.has_value());
    REQUIRE(staged_decoder.has_value());

    std::array<float, 4096> source_pcm{};
    std::array<float, 4096> staged_pcm{};
    while (true) {
        const auto source_read = (*source_decoder)->read_frames(source_pcm);
        const auto staged_read = (*staged_decoder)->read_frames(staged_pcm);
        REQUIRE(source_read.has_value());
        REQUIRE(staged_read.has_value());
        CHECK(*source_read == *staged_read);
        if (*source_read == 0) {
            break;
        }
        CHECK(
            std::equal(source_pcm.begin(), source_pcm.begin() + *source_read, staged_pcm.begin()));
    }
    CHECK_FALSE((*staged_decoder)->damage().has_value());

    std::filesystem::remove_all(directory);
}
