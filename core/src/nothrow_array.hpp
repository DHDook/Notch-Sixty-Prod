// Fixed-size heap array whose allocation reports failure instead of throwing (E21 S4, gap G1). Used by the C interface
// Create functions of the core that must return null on out-of-memory in a translation unit built without exceptions.
// Control thread only: allocate() allocates; indexing and size() never do. Used by remote_tonal; the other ANC classes still
// size std::vector members in their constructors, so an out-of-memory there aborts under -fno-exceptions (gap G25).
#pragma once

#include <cstddef>
#include <memory>
#include <new>

namespace n60 {

template <typename T>
class NothrowArray {
public:
    // Allocates count value-initialised elements, replacing any previous contents. Returns false (and leaves the array
    // empty) when the allocation fails.
    bool allocate(std::size_t count) noexcept {
        data_.reset(new (std::nothrow) T[count]());
        size_ = data_ ? count : 0;
        return data_ != nullptr;
    }
    std::size_t size() const noexcept { return size_; }
    T &operator[](std::size_t i) noexcept { return data_[i]; }
    const T &operator[](std::size_t i) const noexcept { return data_[i]; }

private:
    std::unique_ptr<T[]> data_;
    std::size_t size_{0};
};

}  // namespace n60
