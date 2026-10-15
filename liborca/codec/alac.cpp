#include "liborca/codec/alac.hpp"

#include "liborca/base/logging.hpp"

extern "C" {
#include "liborca/codec/alac_shim.h"
}

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>

namespace orca::codec {

namespace {

class AlacEngine final : public Engine {
public:
    static auto open(std::span<const std::byte> config) -> expected<std::unique_ptr<Engine>> {
        orca_alac_info info{};
        orca_alac_decoder* const native =
            orca_alac_decoder_create(reinterpret_cast<const std::uint8_t*>(config.data()),
                                     static_cast<std::uint32_t>(config.size()), &info);
        if (native == nullptr) {
            return fail(ErrorCode::parse, "alac: cannot open stream");
        }
        if (info.channels == 0 || info.sample_rate == 0 || info.frame_length == 0 ||
            info.bit_depth == 0) {
            orca_alac_decoder_destroy(native);
            return fail(ErrorCode::parse, "alac: invalid stream format");
        }

        auto engine = std::make_unique<AlacEngine>(native);
        engine->max_packet_frames = info.frame_length;
        engine->channels = static_cast<std::uint16_t>(info.channels);
        engine->sample_rate = info.sample_rate;
        engine->bits_per_sample = static_cast<std::uint16_t>(info.bit_depth);
        engine->preroll_packets = 0;
        return engine;
    }

    ~AlacEngine() override {
        if (native_ != nullptr) {
            orca_alac_decoder_destroy(native_);
        }
    }

    [[nodiscard]] auto has_integer_samples() const -> bool override {
        return true;
    }

    [[nodiscard]] auto decode(std::span<const std::byte> packet, std::span<float> output)
        -> expected<std::uint32_t> override {
        ORCA_ASSERT(native_ != nullptr);
        std::uint32_t frames = 0;
        if (orca_alac_decoder_decode(native_, reinterpret_cast<const std::uint8_t*>(packet.data()),
                                     static_cast<std::uint32_t>(packet.size()), output.data(),
                                     &frames) != 0) {
            return fail(ErrorCode::parse, "alac: decode failed");
        }
        return frames;
    }

    [[nodiscard]] auto decode_i32(std::span<const std::byte> packet, std::span<std::int32_t> output)
        -> expected<std::uint32_t> override {
        ORCA_ASSERT(native_ != nullptr);
        std::uint32_t frames = 0;
        if (orca_alac_decoder_decode_i32(
                native_, reinterpret_cast<const std::uint8_t*>(packet.data()),
                static_cast<std::uint32_t>(packet.size()), output.data(), &frames) != 0) {
            return fail(ErrorCode::parse, "alac: decode failed");
        }
        return frames;
    }

    void reset() override {}

    explicit AlacEngine(orca_alac_decoder* native) : native_(native) {}

private:
    orca_alac_decoder* native_ = nullptr;
};

}

auto open_alac_engine(std::span<const std::byte> config) -> expected<std::unique_ptr<Engine>> {
    return AlacEngine::open(config);
}

}
