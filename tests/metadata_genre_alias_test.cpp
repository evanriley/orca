#include "liborca/metadata/genre_alias.hpp"

#include <doctest/doctest.h>
#include <string>
#include <string_view>
#include <vector>

namespace {

void expect_folds(std::string_view value, std::string_view key, std::string_view name) {
    const auto folded = orca::metadata::genre_alias::fold(value);
    CHECK(folded.key == key);
    CHECK(folded.name == name);
}

void expect_splits(const std::vector<std::string_view>& values,
                   const std::vector<std::string_view>& names) {
    const auto genres = orca::metadata::genre_alias::fold_all(values);
    REQUIRE(genres.size() == names.size());
    for (std::size_t index = 0; index < names.size(); ++index) {
        CHECK(genres[index].name == names[index]);
    }
}

}

TEST_CASE("spellings of hip hop with or without the rap suffix fold to one genre") {
    expect_folds("Hip-Hop/Rap", "hiphop", "Hip Hop");
    expect_folds("hip hop", "hiphop", "Hip Hop");
    expect_folds("HipHop", "hiphop", "Hip Hop");
    expect_folds("  Hip Hop ", "hiphop", "Hip Hop");
    expect_folds("Rap/Hip Hop", "hiphop", "Hip Hop");
}

TEST_CASE("an ampersand is part of a genre, so R&B/Soul is one genre and not R&B") {
    expect_folds("R&B/Soul", "r&bsoul", "R&B/Soul");
    expect_folds("RnB", "r&b", "R&B");
    expect_folds("r and b", "r&b", "R&B");
    expect_folds("Rhythm & Blues", "r&b", "R&B");
}

TEST_CASE("a genre the table does not know keeps its first spelling under a folded key") {
    expect_folds("East-Coast  hip hop", "eastcoasthiphop", "East Coast Hip Hop");
    expect_folds("Post-Punk Revival", "postpunkrevival", "Post-Punk Revival");
    expect_folds("Brill Building", "brillbuilding", "Brill Building");
    expect_folds("brill-building", "brillbuilding", "brill-building");
    expect_folds("Alt. Rock", "alternativerock", "Alternative Rock");
}

TEST_CASE("a blank or separator-only value has no key") {
    expect_folds("", "", "");
    expect_folds(" - / ", "", "");
}

TEST_CASE("every canonical name folds to itself, so its key is stable") {
    for (const auto& [ignored, canonical] : orca::metadata::genre_alias::all_aliases()) {
        (void)ignored;
        const auto folded = orca::metadata::genre_alias::fold(canonical);
        CHECK(folded.name == canonical);
    }
}

TEST_CASE("a comma or semicolon list in one value is several genres in stated order") {
    expect_splits({"Indie Rock, Rock, Alternative Rock"},
                  {"Indie Rock", "Rock", "Alternative Rock"});
    expect_splits({"Electronic;Ambient ; Downtempo"}, {"Electronic", "Ambient", "Downtempo"});
    expect_splits({"Jazz, Funk", "Soul"}, {"Jazz", "Funk", "Soul"});
}

TEST_CASE("a slash does not split, so a slashed name still folds through the alias table") {
    expect_splits({"R&B/Soul, Hip-Hop/Rap"}, {"R&B/Soul", "Hip Hop"});
}

TEST_CASE("blank parts are dropped and a genre listed twice is kept where it first appears") {
    expect_splits({" , Rock,, ;Pop; rock ;"}, {"Rock", "Pop"});
    expect_splits({"Hip Hop", "Rock, hip-hop"}, {"Hip Hop", "Rock"});
    expect_splits({" ; ", ""}, {});
}

TEST_CASE("a genre name containing a comma is matched whole before splitting") {
    expect_splits({"Folk, World, & Country"}, {"Folk, World, & Country"});
    expect_splits({"Rock; folk, world, & country , Pop"},
                  {"Rock", "Folk, World, & Country", "Pop"});
    expect_splits({"Folk, World, & Country Blues"}, {"Folk", "World", "& Country Blues"});
}
