#pragma once

#include "liborca/base/logging.hpp"

#include <array>
#include <cstddef>
#include <memory>
#include <utility>

namespace orca {

template <typename T, std::size_t Capacity>
class BoundedVector {
public:
    using value_type = T;
    using size_type = std::size_t;
    using iterator = T*;
    using const_iterator = const T*;

    BoundedVector() noexcept = default;
    ~BoundedVector() {
        clear();
    }

    BoundedVector(const BoundedVector& other) {
        copy_from(other);
    }

    auto operator=(const BoundedVector& other) -> BoundedVector& {
        if (this != &other) {
            clear();
            copy_from(other);
        }
        return *this;
    }

    BoundedVector(BoundedVector&& other) noexcept {
        move_from(other);
    }

    auto operator=(BoundedVector&& other) noexcept -> BoundedVector& {
        if (this != &other) {
            clear();
            move_from(other);
        }
        return *this;
    }

    [[nodiscard]] auto size() const noexcept -> size_type {
        return size_;
    }
    [[nodiscard]] static constexpr auto capacity() noexcept -> size_type {
        return Capacity;
    }
    [[nodiscard]] auto empty() const noexcept -> bool {
        return size_ == 0;
    }
    [[nodiscard]] auto full() const noexcept -> bool {
        return size_ == Capacity;
    }

    [[nodiscard]] auto data() noexcept -> T* {
        return reinterpret_cast<T*>(storage_.data());
    }
    [[nodiscard]] auto data() const noexcept -> const T* {
        return reinterpret_cast<const T*>(storage_.data());
    }

    [[nodiscard]] auto begin() noexcept -> iterator {
        return data();
    }
    [[nodiscard]] auto end() noexcept -> iterator {
        return data() + size_;
    }
    [[nodiscard]] auto begin() const noexcept -> const_iterator {
        return data();
    }
    [[nodiscard]] auto end() const noexcept -> const_iterator {
        return data() + size_;
    }

    [[nodiscard]] auto operator[](size_type index) noexcept -> T& {
        ORCA_ASSERT(index < size_);
        return data()[index];
    }
    [[nodiscard]] auto operator[](size_type index) const noexcept -> const T& {
        ORCA_ASSERT(index < size_);
        return data()[index];
    }
    [[nodiscard]] auto front() noexcept -> T& {
        ORCA_ASSERT(size_ > 0);
        return data()[0];
    }
    [[nodiscard]] auto back() noexcept -> T& {
        ORCA_ASSERT(size_ > 0);
        return data()[size_ - 1];
    }
    [[nodiscard]] auto front() const noexcept -> const T& {
        ORCA_ASSERT(size_ > 0);
        return data()[0];
    }
    [[nodiscard]] auto back() const noexcept -> const T& {
        ORCA_ASSERT(size_ > 0);
        return data()[size_ - 1];
    }

    [[nodiscard]] auto try_push_back(const T& value) -> bool {
        if (full()) {
            return false;
        }
        std::construct_at(data() + size_, value);
        ++size_;
        ORCA_ASSERT(size_ <= Capacity);
        return true;
    }

    [[nodiscard]] auto try_push_back(T&& value) -> bool {
        if (full()) {
            return false;
        }
        std::construct_at(data() + size_, std::move(value));
        ++size_;
        ORCA_ASSERT(size_ <= Capacity);
        return true;
    }

    template <typename... Args>
    [[nodiscard]] auto try_emplace_back(Args&&... args) -> T* {
        if (full()) {
            return nullptr;
        }
        T* slot = data() + size_;
        std::construct_at(slot, std::forward<Args>(args)...);
        ++size_;
        ORCA_ASSERT(size_ <= Capacity);
        return slot;
    }

    void pop_back() noexcept {
        if (size_ > 0) {
            --size_;
            std::destroy_at(data() + size_);
        } else {
            ORCA_ASSERT(false && "BoundedVector pop_back on empty");
        }
    }

    void clear() noexcept {
        ORCA_ASSERT(size_ <= Capacity);
        while (size_ > 0) {
            pop_back();
        }
    }

private:
    void copy_from(const BoundedVector& other) {
        ORCA_ASSERT(other.size_ <= Capacity);
        for (const T& value : other) {
            std::construct_at(data() + size_, value);
            ++size_;
        }
        ORCA_ASSERT(size_ <= Capacity);
    }

    void move_from(BoundedVector& other) noexcept {
        ORCA_ASSERT(other.size_ <= Capacity);
        for (T& value : other) {
            std::construct_at(data() + size_, std::move(value));
            ++size_;
        }
        other.clear();
        ORCA_ASSERT(size_ <= Capacity);
    }

    alignas(T) std::array<std::byte, sizeof(T) * Capacity> storage_{};
    size_type size_ = 0;
};

}
