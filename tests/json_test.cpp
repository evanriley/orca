#include "liborca/json/json.hpp"

#include <cstddef>
#include <doctest/doctest.h>
#include <string>

TEST_CASE("json round trips an object") {
    const std::string text = R"({"name":"orca","count":3,"tags":["a","b"],"ok":true})";
    const auto document = orca::json::Document::parse(text);
    REQUIRE(document.has_value());
    CHECK(document->valid());

    const auto dumped = document->dump();
    REQUIRE(dumped.has_value());

    const auto reparsed = orca::json::Document::parse(*dumped);
    REQUIRE(reparsed.has_value());
    const auto redumped = reparsed->dump();
    REQUIRE(redumped.has_value());
    CHECK(*dumped == *redumped);
}

TEST_CASE("json pretty output differs from compact output") {
    const auto document = orca::json::Document::parse(R"({"a":1})");
    REQUIRE(document.has_value());
    const auto compact = document->dump(false);
    const auto pretty = document->dump(true);
    REQUIRE(compact.has_value());
    REQUIRE(pretty.has_value());
    CHECK(*compact != *pretty);
    CHECK(pretty->find('\n') != std::string::npos);
}

TEST_CASE("json refuses oversized input") {
    const std::string text = R"({"a":"0123456789"})";
    const auto refused = orca::json::Document::parse(text, 4);
    REQUIRE_FALSE(refused.has_value());
    CHECK(refused.error().code == orca::ErrorCode::out_of_range);

    const auto accepted = orca::json::Document::parse(text, text.size());
    CHECK(accepted.has_value());
}

TEST_CASE("json reports malformed input") {
    const auto document = orca::json::Document::parse(R"({"a":})");
    REQUIRE_FALSE(document.has_value());
    CHECK(document.error().code == orca::ErrorCode::parse);
}

TEST_CASE("json empty document dumps to an error") {
    const orca::json::Document document;
    CHECK_FALSE(document.valid());
    CHECK_FALSE(document.dump().has_value());
}
