#include "liborca/codec/aac.hpp"

#include "liborca/base/logging.hpp"

extern "C" {
#include "liborca/codec/aac_shim.h"
}

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>

namespace orca::codec {

namespace {

class AacEngine final : public Engine {
public:
    static auto open(std::span<const std::byte> config, std::span<const std::byte> first_unit)
        -> expected<std::unique_ptr<Engine>> {
        orca_aac_info info{};
        orca_aac_decoder* const native =
            orca_aac_decoder_create(reinterpret_cast<const std::uint8_t*>(config.data()),
                                    static_cast<std::uint32_t>(config.size()),
                                    reinterpret_cast<const std::uint8_t*>(first_unit.data()),
                                    static_cast<std::uint32_t>(first_unit.size()), &info);
        if (native == nullptr) {
            return fail(ErrorCode::parse, "aac: cannot open stream");
        }
        if (info.channels == 0 || info.sample_rate == 0 || info.max_frames == 0) {
            orca_aac_decoder_destroy(native);
            return fail(ErrorCode::parse, "aac: invalid stream format");
        }

        auto engine = std::make_unique<AacEngine>(native);
        engine->max_packet_frames = info.max_frames;
        engine->channels = static_cast<std::uint16_t>(info.channels);
        engine->sample_rate = info.sample_rate;
        engine->bits_per_sample = std::nullopt;
        engine->preroll_packets = 2;
        return engine;
    }

    ~AacEngine() override {
        if (native_ != nullptr) {
            orca_aac_decoder_destroy(native_);
        }
    }

    [[nodiscard]] auto decode(std::span<const std::byte> packet, std::span<float> output)
        -> expected<std::uint32_t> override {
        ORCA_ASSERT(native_ != nullptr);
        std::uint32_t frames = 0;
        if (orca_aac_decoder_decode(native_, reinterpret_cast<const std::uint8_t*>(packet.data()),
                                    static_cast<std::uint32_t>(packet.size()), output.data(),
                                    &frames) != 0) {
            return fail(ErrorCode::parse, "aac: decode failed");
        }
        return frames;
    }

    void reset() override {
        (void)orca_aac_decoder_reset(native_);
    }

    explicit AacEngine(orca_aac_decoder* native) : native_(native) {}

private:
    orca_aac_decoder* native_ = nullptr;
};

}

auto open_aac_engine(std::span<const std::byte> config, std::span<const std::byte> first_unit)
    -> expected<std::unique_ptr<Engine>> {
    return AacEngine::open(config, first_unit);
}

}
